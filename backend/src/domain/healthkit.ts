// HealthKit workout dump (contract between the iOS app and the server) and derived summary.
// The dump is the lossless source of truth (D9); everything else is recomputable from it.
import { z } from "zod";
import { localParts } from "./time.ts";

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

/** Bump when summarize() changes; the recompute job rebuilds older summaries from stored dumps. */
export const SUMMARY_VERSION = 3;

type Sport = "run" | "bike" | "swim" | "strength" | "other";
type Kind = "training" | "recovery";

// HKWorkoutActivityType raw values → our sport/subSport/kind and a readable name.
const TYPES: Record<number, { sport: Sport; sub?: string; kind?: Kind; name: string }> = {
  37: { sport: "run", name: "Run" },
  13: { sport: "bike", name: "Ride" },
  46: { sport: "swim", name: "Swim" },
  20: { sport: "strength", sub: "functional", name: "Functional strength" },
  50: { sport: "strength", sub: "traditional", name: "Strength" },
  59: { sport: "strength", sub: "core", name: "Core" },
  63: { sport: "other", sub: "hiit", name: "HIIT" },
  11: { sport: "other", sub: "cross_training", name: "Cross training" },
  52: { sport: "other", sub: "walk", name: "Walk" },
  24: { sport: "other", sub: "hike", name: "Hike" },
  35: { sport: "other", sub: "rowing", name: "Rowing" },
  16: { sport: "other", sub: "elliptical", name: "Elliptical" },
  60: { sport: "other", sub: "xc_ski", name: "Cross-country ski" },
  82: { sport: "other", sub: "multisport", name: "Swim-bike-run" },
  83: { sport: "other", sub: "transition", name: "Transition" },
  57: { sport: "other", sub: "yoga", kind: "recovery", name: "Yoga" },
  62: { sport: "other", sub: "flexibility", kind: "recovery", name: "Flexibility" },
  29: { sport: "other", sub: "mind_and_body", kind: "recovery", name: "Mind & body" },
  33: { sport: "other", sub: "recovery", kind: "recovery", name: "Preparation & recovery" },
  80: { sport: "other", sub: "cooldown", kind: "recovery", name: "Cooldown" },
  72: { sport: "other", sub: "tai_chi", kind: "recovery", name: "Tai chi" },
};

export function sportOf(dump: HealthKitDump): {
  sport: Sport;
  subSport: string | null;
  kind: Kind;
  name: string;
} {
  const t = TYPES[dump.workout.activityType] ??
    { sport: "other" as const, sub: `hk_${dump.workout.activityType}`, name: "Workout" };
  const meta = dump.workout.metadata;
  const indoor = meta.HKIndoorWorkout === true || meta.HKIndoorWorkout === 1;
  let sub = t.sub ?? null;
  let name = t.name;
  if (t.sport === "run" && indoor) [sub, name] = ["treadmill", "Treadmill run"];
  if (t.sport === "bike" && indoor) [sub, name] = ["indoor_bike", "Indoor ride"];
  if (t.sport === "swim") {
    const loc = meta.HKSwimmingLocationType;
    if (loc === 1) [sub, name] = ["pool", "Pool swim"];
    if (loc === 2) [sub, name] = ["open_water", "Open water swim"];
  }
  return { sport: t.sport, subSport: sub, kind: t.kind ?? "training", name };
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
const round = (x: number | null, d = 0) =>
  x === null || Number.isNaN(x) ? null : Math.round(x * 10 ** d) / 10 ** d;

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
  ).map((x) => x[2]);
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

/** Seconds of pause (pause→resume pairs). */
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

/** Below this speed you are standing (waiting at a start line counts as not moving; walking does). */
const MOVING_MIN_SPEED: Record<string, number> = { run: 0.5, other: 0.5, bike: 1.0 };

/**
 * Moving time from distance samples: sum of sample intervals whose speed ≥ threshold.
 * Falls back to elapsed − explicit pauses when there are no distance samples.
 */
function movingTime(dump: HealthKitDump, sport: string, subSport: string | null): {
  sec: number;
  basis: string;
} {
  const elapsed = dump.workout.durationSec;
  const fallback = { sec: Math.max(0, elapsed - pausedSec(dump)), basis: "elapsed − pauses" };
  if (sport === "swim") {
    // Each distance sample is a length swum; rests between lengths have no samples.
    const lengths = dump.samples.distanceSwimming?.values ?? [];
    if (!lengths.length) return fallback;
    const swim = lengths.reduce((a, [s, e]) => a + Math.max(0, e - s), 0);
    return { sec: Math.min(swim, elapsed), basis: "sum of swim lengths (rests excluded)" };
  }
  const virtual = subSport === "indoor_bike" || subSport === "treadmill";
  const series = dump.samples[distanceKey(sport)]?.values ?? [];
  if (virtual || series.length < 10 || sport === "strength") return fallback;
  const min = MOVING_MIN_SPEED[sport] ?? 0.5;
  let sec = 0;
  for (const [s, e, v] of series) {
    const d = e - s;
    if (d > 0 && v / d >= min) sec += d;
  }
  return { sec: Math.min(sec, elapsed), basis: `distance samples with speed ≥ ${min} m/s` };
}

export function summarize(dump: HealthKitDump) {
  const { sport, subSport, kind, name } = sportOf(dump);
  const w = dump.workout;
  const meta = w.metadata;
  const elapsed = w.durationSec;
  const moving = movingTime(dump, sport, subSport);
  const dk = distanceKey(sport);
  const distance = w.totalDistanceM ?? (dump.samples[dk] ? sumIn(dump, dk, 0, elapsed) : null);
  const hr = values(dump, "heartRate");
  const km = distance ? distance / 1000 : null;
  const footSport = sport === "run" || subSport === "walk" || subSport === "hike";
  const timezone = typeof meta.HKTimeZone === "string" ? meta.HKTimeZone : null;
  const hasDetail = hr.length > 0 || dump.route.length > 0;
  const virtualDistance = subSport === "indoor_bike" || subSport === "treadmill";
  return {
    v: SUMMARY_VERSION,
    sport,
    subSport,
    kind,
    name,
    startLocal: timezone ? localParts(new Date(w.start), timezone).time : null,
    elapsedSec: Math.round(elapsed),
    movingSec: Math.round(moving.sec),
    movingBasis: moving.basis,
    distanceM: round(distance, 1),
    distanceKind: distance === null ? null : virtualDistance ? "virtual" : "measured",
    paceSecPerKm: footSport && km ? Math.round(moving.sec / km) : null,
    paceElapsedSecPerKm: footSport && km ? Math.round(elapsed / km) : null,
    paceSecPer100m: sport === "swim" && distance ? Math.round(moving.sec / (distance / 100)) : null,
    paceWithRestsSecPer100m: sport === "swim" && distance
      ? Math.round(elapsed / (distance / 100))
      : null,
    speedKmh: sport === "bike" && km ? round(km / (moving.sec / 3600), 1) : null,
    hr: hr.length
      ? { avg: round(avg(hr)), max: Math.round(Math.max(...hr)), samples: hr.length }
      : null,
    elevationGainM: round(
      num(meta.HKElevationAscended, ["m"]) ??
        ((num(meta.HKElevationAscended, ["cm"]) ?? NaN) / 100),
      1,
    ),
    energyKcal: round(
      w.totalEnergyKcal ??
        (dump.samples.activeEnergyBurned ? sumIn(dump, "activeEnergyBurned", 0, elapsed) : null),
    ),
    weather: meta.HKWeatherTemperature !== undefined || meta.HKWeatherHumidity !== undefined
      ? {
        tempC: round(temperatureC(meta.HKWeatherTemperature), 1),
        humidityPct: round(percent(meta.HKWeatherHumidity)),
      }
      : null,
    indoor: meta.HKIndoorWorkout === true || meta.HKIndoorWorkout === 1,
    /** summary_only: the source wrote totals without samples (e.g. Strava copies). */
    detail: hasDetail ? "full" : "summary_only",
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
        lengths: dump.samples.distanceSwimming?.values.length ?? null,
        strokes: dump.samples.swimmingStrokeCount
          ? Math.round(sumIn(dump, "swimmingStrokeCount", 0, elapsed))
          : null,
        paceConfidence:
          "medium — the watch detects lengths and rests itself; check against your log",
      }
      : undefined,
    routePoints: dump.route.length,
    device: w.device?.name ?? w.device?.model ?? null,
    sourceApp: w.source.name,
    sourceBundle: w.source.bundleId,
    timezone,
  };
}
export type Summary = ReturnType<typeof summarize>;

/** Default title when neither the athlete nor the coach named the activity. */
export function defaultTitle(s: Summary): string {
  const km = s.distanceM && s.distanceKind === "measured"
    ? ` ${(s.distanceM / 1000).toFixed(1)} km`
    : "";
  return `${s.name}${km}`;
}

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
