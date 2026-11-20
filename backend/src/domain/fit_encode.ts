// HealthKit dump → FIT activity file (spike S3, docs/spikes/S3-dump-to-fit.md). Pure: dump in,
// bytes out. For services that take FIT (Strava, intervals.icu, get_activity_file kind 'fit').
// The dump stays the source of truth (D9); the FIT is a lossy view: 1 Hz records, one lap set.
import { Encoder, Profile } from "@garmin/fitsdk";
import { type HealthKitDump, lapsOf, sportOf, summarize } from "./healthkit.ts";

// deno-lint-ignore no-explicit-any
type Mesg = Record<string, any>;

/** HKWorkoutActivityType (+ indoor/swim location) → FIT sport / sub sport. */
function fitSport(dump: HealthKitDump): { sport: string; subSport: string } {
  const { subSport } = sportOf(dump);
  switch (dump.workout.activityType) {
    case 37:
      return { sport: "running", subSport: subSport === "treadmill" ? "treadmill" : "generic" };
    case 13:
      return { sport: "cycling", subSport: subSport === "indoor_bike" ? "indoorCycling" : "road" };
    case 46:
      return {
        sport: "swimming",
        subSport: subSport === "pool"
          ? "lapSwimming"
          : subSport === "open_water"
          ? "openWater"
          : "generic",
      };
    case 52:
      return { sport: "walking", subSport: "generic" };
    case 24:
      return { sport: "hiking", subSport: "generic" };
    case 60:
      return { sport: "crossCountrySkiing", subSport: "generic" };
    case 35:
      return { sport: "rowing", subSport: "generic" };
    case 16:
      return { sport: "fitnessEquipment", subSport: "elliptical" };
    case 50:
    case 20:
    case 59:
      return { sport: "training", subSport: "strengthTraining" };
    case 57:
      return { sport: "training", subSport: "yoga" };
    default:
      return { sport: "generic", subSport: "generic" };
  }
}

/**
 * Per-second grid of a sample series. Instants are linearly interpolated across gaps ≤ maxGap s;
 * intervals (distance, steps, strokes) are spread uniformly and returned as per-second amounts.
 */
function instants(dump: HealthKitDump, key: string, n: number, maxGap: number): (number | null)[] {
  const out: (number | null)[] = new Array(n).fill(null);
  const vs = (dump.samples[key]?.values ?? []).map(([s, e, v]) => [(s + e) / 2, v] as const)
    .sort((a, b) => a[0] - b[0]);
  for (let i = 0; i < vs.length; i++) {
    const [t, v] = vs[i];
    const sec = Math.round(t);
    if (sec >= 0 && sec < n) out[sec] = v;
    const next = vs[i + 1];
    if (!next || next[0] - t > maxGap) continue;
    for (let s = Math.ceil(t); s < next[0] && s < n; s++) {
      if (s < 0) continue;
      out[s] = v + (next[1] - v) * (s - t) / (next[0] - t);
    }
  }
  return out;
}

function perSecond(dump: HealthKitDump, key: string, n: number): Float64Array | null {
  const vs = dump.samples[key]?.values;
  if (!vs?.length) return null;
  const out = new Float64Array(n);
  for (const [s, e, v] of vs) {
    if (e <= s) {
      const i = Math.floor(s);
      if (i >= 0 && i < n) out[i] += v;
      continue;
    }
    const rate = v / (e - s);
    for (let i = Math.max(0, Math.floor(s)); i < Math.min(n, Math.ceil(e)); i++) {
      out[i] += rate * (Math.min(e, i + 1) - Math.max(s, i));
    }
  }
  return out;
}

function distanceKey(dump: HealthKitDump): string {
  const t = dump.workout.activityType;
  return t === 13
    ? "distanceCycling"
    : t === 46
    ? "distanceSwimming"
    : t === 60
    ? "distanceCrossCountrySkiing"
    : "distanceWalkingRunning";
}

const SEMI = 2 ** 31 / 180;

export interface FitOptions {
  /** file_id.serial_number; the caller passes something stable (e.g. from the workout uuid). */
  serial?: number;
}

export function dumpToFit(dump: HealthKitDump, opts: FitOptions = {}): Uint8Array {
  const w = dump.workout;
  const start = new Date(w.start);
  // HKWorkout.duration excludes pauses; FIT elapsed time is wall clock, timer time is duration.
  const wall = Math.max(w.durationSec, (new Date(w.end).getTime() - start.getTime()) / 1000);
  const n = Math.max(1, Math.floor(wall) + 1);
  const at = (sec: number) => new Date(start.getTime() + Math.round(sec * 1000));
  const off = (iso: string) => (new Date(iso).getTime() - start.getTime()) / 1000;
  const { sport, subSport } = fitSport(dump);
  const summary = summarize(dump);
  const run = w.activityType === 37;
  const bike = w.activityType === 13;
  const swim = w.activityType === 46;

  // ---- per-second channels ----
  const hr = instants(dump, "heartRate", n, 30);
  const power = instants(dump, bike ? "cyclingPower" : "runningPower", n, 10);
  const runSpeed = run ? instants(dump, "runningSpeed", n, 10) : null;
  const bikeCad = bike ? instants(dump, "cyclingCadence", n, 10) : null;
  const vo = run ? instants(dump, "runningVerticalOscillation", n, 15) : null;
  const gct = run ? instants(dump, "runningGroundContactTime", n, 15) : null;
  const stride = run ? instants(dump, "runningStrideLength", n, 15) : null;
  const dist = perSecond(dump, distanceKey(dump), n);
  const steps = run ? perSecond(dump, "stepCount", n) : null;
  const route: (number[] | null)[] = new Array(n).fill(null);
  for (const p of dump.route) {
    const s = Math.round(p[0]);
    if (s >= 0 && s < n) route[s] = p;
  }
  const indoor = summary.indoor;

  const enc = new Encoder();
  enc.onMesg(Profile.MesgNum.FILE_ID, {
    type: "activity",
    manufacturer: "development",
    product: 0,
    productName: "zone2.day",
    timeCreated: start,
    serialNumber: opts.serial ?? 1,
  });
  enc.onMesg(Profile.MesgNum.DEVICE_INFO, {
    timestamp: start,
    deviceIndex: "creator",
    manufacturer: "development",
    productName: (w.device?.name ?? w.source.name).slice(0, 40),
  });
  enc.onMesg(Profile.MesgNum.EVENT, { timestamp: start, event: "timer", eventType: "start" });

  // Pauses: HK pause/resume → FIT timer stop/start, written in time order between records.
  const timer = w.events.filter((e) => e.type === "pause" || e.type === "resume")
    .map((e) => ({ t: off(e.start), stop: e.type === "pause" }))
    .sort((a, b) => a.t - b.t);
  let ti = 0;
  const pauses: [number, number][] = [];
  for (let i = 0; i < timer.length; i++) {
    if (!timer[i].stop) continue;
    const resume = timer.slice(i + 1).find((x) => !x.stop);
    pauses.push([timer[i].t, resume?.t ?? wall]);
  }
  const pausedIn = (a: number, b: number) =>
    pauses.reduce((acc, [s, e]) => acc + Math.max(0, Math.min(b, e) - Math.max(a, s)), 0);

  let cum = 0;
  const window = 10;
  for (let s = 0; s < n; s++) {
    while (ti < timer.length && timer[ti].t <= s) {
      enc.onMesg(Profile.MesgNum.EVENT, {
        timestamp: at(timer[ti].t),
        event: "timer",
        eventType: timer[ti].stop ? "stop" : "start",
      });
      ti++;
    }
    const rec: Mesg = { timestamp: at(s) };
    if (dist) {
      cum += dist[s];
      rec.distance = cum;
    }
    const p = !indoor ? route[s] : null;
    if (p) {
      rec.positionLat = Math.round(p[1] * SEMI);
      rec.positionLong = Math.round(p[2] * SEMI);
      rec.enhancedAltitude = p[3];
    }
    if (hr[s] !== null) rec.heartRate = Math.round(hr[s]!);
    if (power[s] !== null) rec.power = Math.round(power[s]!);
    // Speed: watch's running speed, else GPS speed, else distance over the last few seconds.
    let speed: number | null = runSpeed?.[s] ?? null;
    if (speed === null && p && p[6] >= 0) speed = p[6];
    if (speed === null && dist && s >= window) {
      let d = 0;
      for (let k = s - window + 1; k <= s; k++) d += dist[k];
      speed = d / window;
    }
    if (speed !== null) rec.enhancedSpeed = Math.round(speed * 1000) / 1000;
    if (bikeCad?.[s] != null) rec.cadence = Math.round(bikeCad[s]!);
    if (steps && s >= window - 1) {
      let st = 0;
      for (let k = s - window + 1; k <= s; k++) st += steps[k];
      const strides = (st / window) * 60 / 2; // FIT running cadence = strides per minute
      if (strides > 0) {
        rec.cadence = Math.floor(strides);
        rec.fractionalCadence = Math.round((strides - Math.floor(strides)) * 128) / 128;
      }
    }
    if (vo?.[s] != null) rec.verticalOscillation = vo[s]! * 10; // cm → mm
    if (gct?.[s] != null) rec.stanceTime = gct[s]!;
    if (stride?.[s] != null) rec.stepLength = stride[s]! * 1000; // m → mm
    if (Object.keys(rec).length > 1) enc.onMesg(Profile.MesgNum.RECORD, rec);
  }

  // ---- laps: manual intervals if any, else the first automatic chain, else the whole workout ----
  const all = lapsOf(dump);
  const manual = all.filter((l) => l.kind === "manual");
  const auto = all.filter((l) => l.kind === "segment" || l.kind === "split_km");
  const firstKind = auto[0]?.kind;
  let laps = manual.length ? manual : auto.filter((l) => l.kind === firstKind);
  // Overlapping chains (e.g. pool sets) → keep a non-overlapping, time-ordered subset.
  const kept: typeof laps = [];
  for (const l of [...laps].sort((a, b) => a.startSec - b.startSec)) {
    if (!kept.length || l.startSec >= kept[kept.length - 1].endSec - 1) kept.push(l);
  }
  laps = kept;
  const lapMesgs: Mesg[] = laps.length
    ? laps.map((l, i) => ({
      messageIndex: i,
      timestamp: at(l.endSec),
      startTime: at(l.startSec),
      totalElapsedTime: l.durationSec,
      totalTimerTime: l.durationSec - pausedIn(l.startSec, l.endSec),
      totalDistance: l.distanceM ?? undefined,
      avgHeartRate: l.avgHr ?? undefined,
      maxHeartRate: l.maxHr ?? undefined,
      avgPower: l.powerAvg ?? undefined,
      avgCadence: l.cadence === null ? undefined : run ? Math.round(l.cadence / 2) : l.cadence,
      avgSpeed: l.distanceM && l.movingSec ? l.distanceM / l.movingSec : undefined,
      lapTrigger: l.kind === "manual"
        ? "manual"
        : l.kind === "split_km"
        ? "distance"
        : "sessionEnd",
      event: "lap",
      eventType: "stop",
      sport,
      subSport,
    }))
    : [{
      messageIndex: 0,
      timestamp: at(wall),
      startTime: start,
      totalElapsedTime: wall,
      totalTimerTime: w.durationSec,
      totalDistance: summary.distanceM ?? undefined,
      avgHeartRate: summary.hr?.avg ?? undefined,
      maxHeartRate: summary.hr?.max ?? undefined,
      lapTrigger: "sessionEnd",
      event: "lap",
      eventType: "stop",
      sport,
      subSport,
    }];

  // Pool swim: one active length per watch length event, with strokes and stroke style.
  if (swim) {
    const strokeName: Record<string, string> = {
      freestyle: "freestyle",
      backstroke: "backstroke",
      breaststroke: "breaststroke",
      butterfly: "butterfly",
      mixed: "im",
      drill: "drill",
    };
    all.filter((l) => l.kind === "lap").forEach((l, i) => {
      enc.onMesg(Profile.MesgNum.LENGTH, {
        messageIndex: i,
        timestamp: at(l.endSec),
        startTime: at(l.startSec),
        totalElapsedTime: l.durationSec,
        totalTimerTime: l.durationSec,
        totalStrokes: l.strokes ?? undefined,
        swimStroke: l.stroke ? strokeName[l.stroke] : undefined,
        lengthType: "active",
        event: "length",
        eventType: "stop",
      });
    });
  }
  for (const l of lapMesgs) enc.onMesg(Profile.MesgNum.LAP, l);

  const end = at(wall);
  enc.onMesg(Profile.MesgNum.EVENT, { timestamp: end, event: "timer", eventType: "stopAll" });
  enc.onMesg(Profile.MesgNum.SESSION, {
    messageIndex: 0,
    timestamp: end,
    startTime: start,
    sport,
    subSport,
    totalElapsedTime: wall,
    totalTimerTime: w.durationSec,
    totalDistance: summary.distanceM ?? undefined,
    totalCalories: summary.energyKcal ?? undefined,
    avgHeartRate: summary.hr?.avg ?? undefined,
    maxHeartRate: summary.hr?.max ?? undefined,
    avgPower: summary.cycling?.powerAvg ?? summary.running?.powerAvg ?? undefined,
    totalAscent: summary.elevationGainM ?? undefined,
    poolLength: summary.swim?.poolLengthM ?? undefined,
    poolLengthUnit: summary.swim?.poolLengthM ? "metric" : undefined,
    numActiveLengths: summary.swim?.lengths ?? undefined,
    firstLapIndex: 0,
    numLaps: lapMesgs.length,
    event: "session",
    eventType: "stop",
    trigger: "activityEnd",
  });
  const tz = summary.timezone;
  const localOffsetSec = tz ? tzOffsetSec(start, tz) : 0;
  enc.onMesg(Profile.MesgNum.ACTIVITY, {
    timestamp: end,
    totalTimerTime: w.durationSec,
    numSessions: 1,
    type: "manual",
    event: "activity",
    eventType: "stop",
    // local_timestamp = FIT seconds (since 1989-12-31) shifted to local wall time.
    localTimestamp: Math.round((end.getTime() - FIT_EPOCH_MS) / 1000) + localOffsetSec,
  });
  return enc.close();
}

const FIT_EPOCH_MS = Date.UTC(1989, 11, 31);

function tzOffsetSec(d: Date, tz: string): number {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: tz,
    hourCycle: "h23",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).formatToParts(d);
  const g = (t: string) => Number(parts.find((p) => p.type === t)!.value);
  const local = Date.UTC(g("year"), g("month") - 1, g("day"), g("hour"), g("minute"), g("second"));
  return Math.round((local - d.getTime()) / 1000);
}
