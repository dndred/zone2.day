// FIT activity file → the HealthKit dump shape, so summary, laps and streams share one code path
// (docs/05-sync.md §7). Pure: bytes in, dump out. The original FIT is kept byte for byte (D9).
import { Decoder, Stream } from "@garmin/fitsdk";
import type { HealthKitDump } from "./healthkit.ts";

export class InvalidFitError extends Error {}

// deno-lint-ignore no-explicit-any
type Mesg = Record<string, any>;

/** FIT sport (+ sub sport) → HKWorkoutActivityType raw value (see TYPES in healthkit.ts). */
function activityType(sport: string, sub: string): number {
  if (sport === "running") return 37;
  if (sport === "cycling") return 13;
  if (sport === "swimming") return 46;
  if (sport === "walking") return 52;
  if (sport === "hiking") return 24;
  if (sport === "rowing" || sub === "indoorRowing") return 35;
  if (sub === "elliptical") return 16;
  if (sport === "crossCountrySkiing") return 60;
  if (sport === "training") return sub === "yoga" ? 57 : sub === "flexibilityTraining" ? 62 : 20;
  if (sport === "multisport" || sport === "transition") return 83;
  return 3000; // HKWorkoutActivityType.other
}

const INDOOR_SUBS = new Set([
  "indoorCycling",
  "virtualActivity",
  "spin",
  "treadmill",
  "indoorRunning",
  "indoorRowing",
  "indoorWalking",
]);

const DISTANCE_KEY: Record<number, string> = {
  13: "distanceCycling",
  46: "distanceSwimming",
};

const MAKERS: Record<string, string> = {
  mywhoosh: "MyWhoosh",
  zwift: "Zwift",
  garmin: "Garmin",
  wahooFitness: "Wahoo",
  trainerroad: "TrainerRoad",
  coros: "COROS",
  suunto: "Suunto",
  polar: "Polar",
  hammerhead: "Hammerhead",
};

/** Readable source name: product name when the file has one, else the manufacturer. */
function sourceName(fileId: Mesg | undefined, device: Mesg | undefined): string {
  const name = fileId?.productName ?? device?.productName;
  if (typeof name === "string" && name.trim()) return name.trim();
  const m = fileId?.manufacturer;
  if (typeof m === "string" && MAKERS[m]) return MAKERS[m];
  if (typeof m === "string" && m !== "development") return m[0].toUpperCase() + m.slice(1);
  return "FIT file";
}

/**
 * Decode an activity FIT. `uuid` becomes workout.uuid (the caller uses the file hash, so
 * re-importing the same file is idempotent).
 */
export function fitToDump(bytes: Uint8Array, uuid: string, exportedAt: Date): HealthKitDump {
  const stream = Stream.fromByteArray(Array.from(bytes));
  if (!Decoder.isFIT(stream)) throw new InvalidFitError("not a FIT file");
  const decoder = new Decoder(Stream.fromByteArray(Array.from(bytes)));
  if (!decoder.checkIntegrity()) throw new InvalidFitError("FIT file is damaged (CRC/size check)");
  const { messages, errors } = new Decoder(Stream.fromByteArray(Array.from(bytes))).read({
    convertDateTimesToDates: true,
    mergeHeartRates: true,
  });
  if (errors.length) throw new InvalidFitError(`FIT decode failed: ${String(errors[0])}`);

  const sessions: Mesg[] = messages.sessionMesgs ?? [];
  const records: Mesg[] = (messages.recordMesgs ?? []).filter((r: Mesg) =>
    r.timestamp instanceof Date
  );
  const fileId: Mesg | undefined = messages.fileIdMesgs?.[0];
  if (fileId?.type && fileId.type !== "activity") {
    throw new InvalidFitError(`FIT file type is '${fileId.type}', expected an activity`);
  }
  if (sessions.length > 1) {
    throw new InvalidFitError(
      `multisport FIT (${sessions.length} sessions) is not supported yet; export each leg separately`,
    );
  }
  const session: Mesg | undefined = sessions[0];
  if (!session && !records.length) throw new InvalidFitError("FIT file has no session or records");

  const start: Date = session?.startTime ?? records[0].timestamp;
  const lastRecord: Date = records.length ? records[records.length - 1].timestamp : start;
  // Wall clock (start → end) vs timer time: HealthKit's duration excludes pauses, like FIT timer.
  const wall: number = session?.totalElapsedTime ??
    (lastRecord.getTime() - start.getTime()) / 1000;
  const elapsed: number = Math.min(session?.totalTimerTime ?? wall, wall);
  const end = new Date(start.getTime() + wall * 1000);
  const sport: string = session?.sport ?? messages.sportMesgs?.[0]?.sport ?? "generic";
  const sub: string = session?.subSport ?? messages.sportMesgs?.[0]?.subSport ?? "generic";
  const type = activityType(sport, sub);
  const indoor = INDOOR_SUBS.has(sub);
  const t = (d: Date) => Math.round((d.getTime() - start.getTime()) / 100) / 10;
  const iso = (d: Date) => d.toISOString();

  // ---- samples: instants as [t, t, v]; distance and steps as deltas over [prev, t] ----
  const samples: HealthKitDump["samples"] = {};
  const push = (key: string, unit: string, s: [number, number, number]) => {
    (samples[key] ??= { unit, values: [] }).values.push(s);
  };
  const run = type === 37;
  const bike = type === 13;
  const distKey = DISTANCE_KEY[type] ?? "distanceWalkingRunning";
  const route: number[][] = [];
  let prev: Mesg | null = null;
  for (const r of records) {
    const at = t(r.timestamp);
    if (at < 0 || at > wall + 1) continue;
    if (typeof r.heartRate === "number" && r.heartRate > 0) {
      push("heartRate", "count/min", [at, at, r.heartRate]);
    }
    if (typeof r.power === "number") {
      push(bike ? "cyclingPower" : "runningPower", "W", [at, at, r.power]);
    }
    const speed = r.enhancedSpeed ?? r.speed;
    if (typeof speed === "number") {
      if (bike) push("cyclingSpeed", "m/s", [at, at, speed]);
      if (run) push("runningSpeed", "m/s", [at, at, speed]);
    }
    if (typeof r.cadence === "number" && bike) {
      push("cyclingCadence", "count/min", [at, at, r.cadence]);
    }
    if (prev) {
      const from = t(prev.timestamp);
      if (at > from) {
        if (typeof r.distance === "number" && typeof prev.distance === "number" && type !== 46) {
          push(distKey, "m", [from, at, Math.max(0, r.distance - prev.distance)]);
        }
        if (run && typeof r.cadence === "number") {
          // FIT running cadence is strides (one foot) per minute.
          const spm = 2 * (r.cadence + (r.fractionalCadence ?? 0));
          push("stepCount", "count", [from, at, spm * (at - from) / 60]);
        }
      }
    }
    // Indoor: positions are the trainer app's virtual world (MyWhoosh writes fake coordinates).
    if (!indoor && typeof r.positionLat === "number" && typeof r.positionLong === "number") {
      const deg = 180 / 2 ** 31;
      route.push([
        at,
        r.positionLat * deg,
        r.positionLong * deg,
        r.enhancedAltitude ?? r.altitude ?? 0,
        0,
        0,
        speed ?? 0,
        0,
      ]);
    }
    prev = r;
  }

  // Pool swim: each active length is a distance sample (rests have none), like the watch writes.
  const metadata: Record<string, unknown> = { HKIndoorWorkout: indoor };
  const lengthEvents: HealthKitDump["workout"]["events"] = [];
  if (type === 46) {
    const pool: number | undefined = session?.poolLength;
    if (sub === "lapSwimming") metadata.HKSwimmingLocationType = 1;
    if (sub === "openWater") metadata.HKSwimmingLocationType = 2;
    if (pool) metadata.HKLapLength = { value: pool, unit: "m" };
    for (const l of (messages.lengthMesgs ?? []) as Mesg[]) {
      if (l.lengthType !== "active" || !(l.startTime instanceof Date)) continue;
      const s = t(l.startTime);
      const e = s + (l.totalElapsedTime ?? 0);
      if (pool) push("distanceSwimming", "m", [s, e, pool]);
      if (typeof l.totalStrokes === "number") {
        push("swimmingStrokeCount", "count", [s, e, l.totalStrokes]);
      }
      // Each length is a lap event, like the watch writes; stroke style by name.
      const style = fitStroke(l.swimStroke);
      lengthEvents.push({
        type: "lap",
        start: iso(l.startTime),
        end: iso(new Date(l.startTime.getTime() + (l.totalElapsedTime ?? 0) * 1000)),
        metadata: style ? { HKSwimmingStrokeStyle: style } : {},
      });
    }
    if (!samples.distanceSwimming && records.length) {
      // Open water: distance from records.
      let p: Mesg | null = null;
      for (const r of records) {
        if (p && typeof r.distance === "number" && typeof p.distance === "number") {
          push("distanceSwimming", "m", [t(p.timestamp), t(r.timestamp), r.distance - p.distance]);
        }
        p = r;
      }
    }
  }
  if (typeof session?.totalAscent === "number") {
    metadata.HKElevationAscended = { value: session.totalAscent, unit: "m" };
  }

  // ---- events: timer stop/start → pause/resume; laps → segments ----
  const events: HealthKitDump["workout"]["events"] = [];
  let running = false;
  for (const e of (messages.eventMesgs ?? []) as Mesg[]) {
    if (e.event !== "timer" || !(e.timestamp instanceof Date)) continue;
    if (e.eventType === "start") {
      if (!running && t(e.timestamp) > 0) {
        events.push({
          type: "resume",
          start: iso(e.timestamp),
          end: iso(e.timestamp),
          metadata: {},
        });
      }
      running = true;
    } else if (e.eventType === "stop" || e.eventType === "stopAll") {
      if (running && t(e.timestamp) < wall - 1) {
        events.push({
          type: "pause",
          start: iso(e.timestamp),
          end: iso(e.timestamp),
          metadata: {},
        });
      }
      running = false;
    }
  }
  const laps: Mesg[] = messages.lapMesgs ?? [];
  if (laps.length > 1) {
    for (const l of laps) {
      if (!(l.startTime instanceof Date) || !l.totalElapsedTime) continue;
      events.push({
        type: "segment",
        start: iso(l.startTime),
        end: iso(new Date(l.startTime.getTime() + l.totalElapsedTime * 1000)),
        metadata: {},
      });
    }
  }

  events.push(...lengthEvents);

  const device: Mesg | undefined = (messages.deviceInfoMesgs ?? []).find((d: Mesg) =>
    d.deviceIndex === "creator" || d.deviceIndex === 0
  );
  const name = sourceName(fileId, device);
  return {
    schema: 1,
    exportedAt: exportedAt.toISOString(),
    workout: {
      uuid,
      activityType: type,
      start: iso(start),
      end: iso(end),
      durationSec: elapsed,
      totalDistanceM: session?.totalDistance ?? null,
      totalEnergyKcal: session?.totalCalories ?? null,
      source: { name, bundleId: `fit.${String(fileId?.manufacturer ?? "unknown")}` },
      device: { name },
      metadata: metadata as HealthKitDump["workout"]["metadata"],
      activities: [],
      events,
    },
    samples,
    route,
  };
}

/** FIT swim_stroke → the names lapsOf() reports (im and its variants count as mixed). */
function fitStroke(v: unknown): string | null {
  if (typeof v !== "string") return null;
  if (["freestyle", "backstroke", "breaststroke", "butterfly", "drill"].includes(v)) return v;
  if (["mixed", "im", "imByRound", "rimo"].includes(v)) return "mixed";
  return null;
}
