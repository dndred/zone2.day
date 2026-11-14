// HealthKit workout dump (contract between the iOS app and the server) and derived summary.
// The dump is the lossless source of truth (D9); everything else is recomputable from it.
import { z } from "zod";

const Quantity = z.object({ value: z.number(), unit: z.string() });
const MetaValue = z.union([z.string(), z.number(), z.boolean(), Quantity]);
const Meta = z.record(z.string(), MetaValue).default({});

/** [startOffsetSec, endOffsetSec, value] relative to workout start. */
const Sample = z.tuple([z.number(), z.number(), z.number()]);

export const HealthKitDump = z.object({
  schema: z.literal(1),
  exportedAt: z.string(),
  app: z.object({ version: z.string() }).optional(),
  workout: z.object({
    uuid: z.string().min(1),
    activityType: z.number().int(),
    start: z.string(),
    end: z.string(),
    durationSec: z.number().nonnegative(),
    totalDistanceM: z.number().nullable().optional(),
    totalEnergyKcal: z.number().nullable().optional(),
    source: z.object({ name: z.string(), bundleId: z.string() }),
    device: z.object({
      name: z.string().optional(),
      model: z.string().optional(),
      hardwareVersion: z.string().optional(),
      softwareVersion: z.string().optional(),
    }).nullable().optional(),
    metadata: Meta,
    activities: z.array(z.object({
      uuid: z.string(),
      activityType: z.number().int(),
      start: z.string(),
      end: z.string().nullable().optional(),
      location: z.enum(["indoor", "outdoor", "unknown"]).optional(),
      metadata: Meta,
    })).default([]),
    events: z.array(z.object({
      type: z.string(), // pause | resume | lap | marker | motionPaused | motionResumed | segment
      start: z.string(),
      end: z.string(),
      metadata: Meta,
    })).default([]),
  }),
  /** Key = HKQuantityTypeIdentifier without prefix (heartRate, runningPower, …). */
  samples: z.record(z.string(), z.object({ unit: z.string(), values: z.array(Sample) })).default(
    {},
  ),
  /** [tOffsetSec, lat, lon, altitudeM, hAccM, vAccM, speedMps, courseDeg] */
  route: z.array(z.array(z.number()).min(3)).default([]),
});
export type HealthKitDump = z.infer<typeof HealthKitDump>;

// HKWorkoutActivityType raw values we care about.
const TYPES: Record<
  number,
  { sport: "run" | "bike" | "swim" | "strength" | "other"; sub?: string }
> = {
  37: { sport: "run" },
  13: { sport: "bike" },
  46: { sport: "swim" },
  20: { sport: "strength", sub: "functional" },
  50: { sport: "strength", sub: "traditional" },
  52: { sport: "other", sub: "walk" },
  24: { sport: "other", sub: "hike" },
  82: { sport: "other", sub: "multisport" },
};

export function sportOf(dump: HealthKitDump): { sport: string; subSport: string | null } {
  const t = TYPES[dump.workout.activityType] ?? { sport: "other" as const };
  const meta = dump.workout.metadata;
  const indoor = meta.HKIndoorWorkout === true || meta.HKIndoorWorkout === 1;
  let sub = t.sub ?? null;
  if (t.sport === "run" && indoor) sub = "treadmill";
  if (t.sport === "bike" && indoor) sub = "indoor_bike";
  if (t.sport === "swim") {
    const loc = meta.HKSwimmingLocationType;
    sub = loc === 1 ? "pool" : loc === 2 ? "open_water" : sub;
  }
  return { sport: t.sport, subSport: sub };
}

const num = (v: unknown, want?: string[]): number | null => {
  if (typeof v === "number") return v;
  if (v && typeof v === "object" && "value" in v) {
    const q = v as { value: number; unit: string };
    if (!want || want.includes(q.unit)) return q.value;
  }
  return null;
};

function temperatureC(v: unknown): number | null {
  if (v && typeof v === "object" && "value" in v) {
    const q = v as { value: number; unit: string };
    if (q.unit === "degF") return (q.value - 32) * 5 / 9;
    if (q.unit === "degC") return q.value;
  }
  return typeof v === "number" ? v : null;
}

function percent(v: unknown): number | null {
  const n = num(v);
  if (n === null) return null;
  return n <= 1 ? n * 100 : n; // HealthKit percent may come as 0…1
}

const avg = (xs: number[]) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null);
const round = (x: number | null, d = 0) => (x === null ? null : Math.round(x * 10 ** d) / 10 ** d);

function values(dump: HealthKitDump, key: string): number[] {
  return dump.samples[key]?.values.map((s) => s[2]) ?? [];
}

/** Sum of interval samples (distance, energy, strokes) overlapping [from, to), prorated. */
export function sumIn(dump: HealthKitDump, key: string, from: number, to: number): number {
  let total = 0;
  for (const [s, e, v] of dump.samples[key]?.values ?? []) {
    if (e <= from || s >= to) continue;
    const len = Math.max(e - s, 1e-6);
    total += v * (Math.min(e, to) - Math.max(s, from)) / len;
  }
  return total;
}

function meanIn(dump: HealthKitDump, key: string, from: number, to: number): number | null {
  const vs = (dump.samples[key]?.values ?? []).filter(([s, e]) =>
    (s + e) / 2 >= from && (s + e) / 2 < to
  )
    .map((x) => x[2]);
  return avg(vs);
}

export interface Lap {
  index: number;
  kind: string;
  startSec: number;
  endSec: number;
  durationSec: number;
  distanceM: number | null;
  avgHr: number | null;
}

const offset = (dump: HealthKitDump, iso: string) =>
  (new Date(iso).getTime() - new Date(dump.workout.start).getTime()) / 1000;

function distanceKey(sport: string): string {
  return sport === "bike"
    ? "distanceCycling"
    : sport === "swim"
    ? "distanceSwimming"
    : "distanceWalkingRunning";
}

export function lapsOf(dump: HealthKitDump): Lap[] {
  const { sport } = sportOf(dump);
  const dk = distanceKey(sport);
  return dump.workout.events
    .filter((e) => e.type === "segment" || e.type === "lap")
    .map((e) => ({ kind: e.type, s: offset(dump, e.start), e: offset(dump, e.end) }))
    .filter((x) => x.e > x.s)
    .sort((a, b) => a.s - b.s)
    .map((x, index) => ({
      index,
      kind: x.kind,
      startSec: round(x.s, 1)!,
      endSec: round(x.e, 1)!,
      durationSec: round(x.e - x.s, 1)!,
      distanceM: dump.samples[dk] ? round(sumIn(dump, dk, x.s, x.e), 1) : null,
      avgHr: round(meanIn(dump, "heartRate", x.s, x.e)),
    }));
}

/** Seconds of pause (pause→resume pairs) — moving time = elapsed − paused. */
function pausedSec(dump: HealthKitDump): number {
  let paused = 0;
  let since: number | null = null;
  const evs = [...dump.workout.events].sort((a, b) => a.start.localeCompare(b.start));
  for (const e of evs) {
    if ((e.type === "pause" || e.type === "motionPaused") && since === null) {
      since = offset(dump, e.start);
    }
    if ((e.type === "resume" || e.type === "motionResumed") && since !== null) {
      paused += offset(dump, e.start) - since;
      since = null;
    }
  }
  return paused;
}

export function summarize(dump: HealthKitDump) {
  const { sport, subSport } = sportOf(dump);
  const w = dump.workout;
  const meta = w.metadata;
  const duration = w.durationSec;
  const moving = Math.max(0, duration - pausedSec(dump));
  const distance = w.totalDistanceM ??
    (dump.samples[distanceKey(sport)] ? sumIn(dump, distanceKey(sport), 0, duration) : null);
  const hr = values(dump, "heartRate");
  const km = distance ? distance / 1000 : null;
  return {
    sport,
    subSport,
    durationSec: Math.round(duration),
    movingSec: Math.round(moving),
    distanceM: round(distance, 1),
    paceSecPerKm: (sport === "run" || subSport === "walk" || subSport === "hike") && km
      ? Math.round(moving / km)
      : null,
    paceSecPer100m: sport === "swim" && distance ? Math.round(moving / (distance / 100)) : null,
    speedKmh: sport === "bike" && km ? round(km / (moving / 3600), 1) : null,
    hr: hr.length
      ? { avg: round(avg(hr)), max: Math.round(Math.max(...hr)), samples: hr.length }
      : null,
    elevationGainM: round(
      num(meta.HKElevationAscended, ["m"]) ??
        ((num(meta.HKElevationAscended, ["cm"]) ?? NaN) / 100),
      1,
    ) ?? null,
    energyKcal: round(
      w.totalEnergyKcal ??
        (dump.samples.activeEnergyBurned ? sumIn(dump, "activeEnergyBurned", 0, duration) : null),
    ),
    weather: meta.HKWeatherTemperature !== undefined || meta.HKWeatherHumidity !== undefined
      ? {
        tempC: round(temperatureC(meta.HKWeatherTemperature), 1),
        humidityPct: round(percent(meta.HKWeatherHumidity)),
      }
      : null,
    indoor: meta.HKIndoorWorkout === true || meta.HKIndoorWorkout === 1,
    running: sport === "run"
      ? {
        powerAvg: round(avg(values(dump, "runningPower"))),
        speedAvgMps: round(avg(values(dump, "runningSpeed")), 2),
        strideLengthM: round(avg(values(dump, "runningStrideLength")), 2),
        verticalOscillationCm: round(avg(values(dump, "runningVerticalOscillation")), 1),
        groundContactMs: round(avg(values(dump, "runningGroundContactTime"))),
      }
      : undefined,
    cycling: sport === "bike"
      ? {
        powerAvg: round(avg(values(dump, "cyclingPower"))),
        powerMax: values(dump, "cyclingPower").length
          ? Math.max(...values(dump, "cyclingPower"))
          : null,
        cadenceAvg: round(avg(values(dump, "cyclingCadence"))),
      }
      : undefined,
    swim: sport === "swim"
      ? {
        poolLengthM: num(meta.HKLapLength, ["m"]),
        strokes: dump.samples.swimmingStrokeCount
          ? Math.round(sumIn(dump, "swimmingStrokeCount", 0, duration))
          : null,
      }
      : undefined,
    routePoints: dump.route.length,
    device: w.device?.name ?? w.device?.model ?? null,
    sourceApp: w.source.name,
    sourceBundle: w.source.bundleId,
    timezone: typeof meta.HKTimeZone === "string" ? meta.HKTimeZone : null,
  };
}
export type Summary = ReturnType<typeof summarize>;

/** Lower = preferred source when two records describe the same session. */
export function sourcePriority(bundleId: string): number {
  if (bundleId.startsWith("com.apple.health")) return 0; // Apple Watch / Workout app
  if (bundleId.includes("strava")) return 9; // Strava copies lose detail (D33)
  return 5;
}

/** Channels for get_activity_streams: resampled into `buckets` over [from, to). */
export function streams(
  dump: HealthKitDump,
  channels: string[],
  from: number,
  to: number,
  buckets: number,
): Record<string, (number | null)[]> {
  const width = (to - from) / buckets;
  const out: Record<string, (number | null)[]> = {
    t: Array.from({ length: buckets }, (_, i) => Math.round(from + i * width)),
  };
  const { sport } = sportOf(dump);
  for (const ch of channels) {
    if (ch === "distance") {
      const dk = distanceKey(sport);
      let acc = sumIn(dump, dk, 0, from);
      out.distance = out.t.map((_, i) => {
        acc += sumIn(dump, dk, from + i * width, from + (i + 1) * width);
        return round(acc, 1);
      });
    } else if (ch === "lat" || ch === "lon" || ch === "altitude") {
      const col = ch === "lat" ? 1 : ch === "lon" ? 2 : 3;
      out[ch] = out.t.map((_, i) => {
        const pts = dump.route.filter((p) =>
          p[0] >= from + i * width && p[0] < from + (i + 1) * width
        );
        return pts.length ? round(avg(pts.map((p) => p[col])), col === 3 ? 1 : 6) : null;
      });
    } else if (dump.samples[ch]) {
      out[ch] = out.t.map((_, i) =>
        round(meanIn(dump, ch, from + i * width, from + (i + 1) * width), 2)
      );
    }
  }
  return out;
}
