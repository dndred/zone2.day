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
export const SUMMARY_VERSION = 7;

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
  /** Moving time inside the lap (same rule as summary.movingSec). */
  movingSec: number;
  avgHr: number | null;
  maxHr: number | null;
  /** Run/walk: by moving time. */
  paceSecPerKm: number | null;
  /** Bike: by moving time. */
  speedKmh: number | null;
  powerAvg: number | null;
  /** Run spm / bike rpm, by moving time. */
  cadence: number | null;
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

/** Below this speed you are standing (waiting at a start line counts as not moving; walking does). */
const MOVING_MIN_SPEED: Record<string, number> = { run: 0.5, other: 0.5, bike: 1.0 };

type Span = [number, number];

/** Sorted, merged copy of spans (adjacent moving samples become one span). */
function merge(spans: Span[]): Span[] {
  const out: Span[] = [];
  for (const [s, e] of [...spans].sort((a, b) => a[0] - b[0])) {
    const last = out[out.length - 1];
    if (last && s <= last[1] + 1e-6) last[1] = Math.max(last[1], e);
    else out.push([s, e]);
  }
  return out;
}

/** [0, elapsed] minus pause→resume pairs. */
function activeSpans(dump: HealthKitDump): Span[] {
  const elapsed = dump.workout.durationSec;
  const evs = [...dump.workout.events].sort((a, b) => a.start.localeCompare(b.start));
  const out: Span[] = [];
  let from = 0;
  let paused = false;
  for (const e of evs) {
    const t = Math.min(Math.max(offset(dump, e.start), 0), elapsed);
    if ((e.type === "pause" || e.type === "motionPaused") && !paused) {
      if (t > from) out.push([from, t]);
      paused = true;
    }
    if ((e.type === "resume" || e.type === "motionResumed") && paused) {
      from = t;
      paused = false;
    }
  }
  if (!paused && elapsed > from) out.push([from, elapsed]);
  return out;
}

const spanSec = (spans: Span[]) => spans.reduce((a, [s, e]) => a + e - s, 0);

/**
 * Moving time from distance samples: sum of sample intervals whose speed ≥ threshold.
 * Falls back to elapsed − explicit pauses when there are no distance samples.
 * `spans` are the moving intervals — cadence and other averages use the same definition.
 */
function movingTime(dump: HealthKitDump, sport: string, subSport: string | null): {
  sec: number;
  basis: string;
  spans: Span[];
} {
  const elapsed = dump.workout.durationSec;
  const active = activeSpans(dump);
  const fallback = { sec: spanSec(active), basis: "elapsed − pauses", spans: active };
  if (sport === "swim") {
    // Each distance sample is a length swum; rests between lengths have no samples.
    const lengths = dump.samples.distanceSwimming?.values ?? [];
    if (!lengths.length) return fallback;
    const spans = merge(lengths.filter(([s, e]) => e > s).map(([s, e]) => [s, e] as Span));
    return {
      sec: Math.min(spanSec(spans), elapsed),
      basis: "sum of swim lengths (rests excluded)",
      spans,
    };
  }
  const virtual = subSport === "indoor_bike" || subSport === "treadmill";
  const series = dump.samples[distanceKey(sport)]?.values ?? [];
  if (virtual || series.length < 10 || sport === "strength") return fallback;
  const min = MOVING_MIN_SPEED[sport] ?? 0.5;
  const spans = merge(
    series.filter(([s, e, v]) => e > s && v / (e - s) >= min).map(([s, e]) => [s, e] as Span),
  );
  return {
    sec: Math.min(spanSec(spans), elapsed),
    basis: `distance samples with speed ≥ ${min} m/s`,
    spans,
  };
}

/** Is t inside one of the merged spans (binary search). */
function inSpans(spans: Span[], t: number): boolean {
  let lo = 0;
  let hi = spans.length - 1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (t < spans[mid][0]) hi = mid - 1;
    else if (t > spans[mid][1]) lo = mid + 1;
    else return true;
  }
  return false;
}

/**
 * Average cadence over moving time, like pace: standing at the start or at traffic lights
 * does not dilute it. Run: steps in moving spans per moving minute (spm). Bike: mean of
 * cadence samples taken while moving, zeros (coasting) excluded.
 */
function cadenceAvg(dump: HealthKitDump, sport: string, moving: { sec: number; spans: Span[] }) {
  if (sport === "run" && dump.samples.stepCount && moving.sec > 0) {
    const steps = moving.spans.reduce((a, [s, e]) => a + sumIn(dump, "stepCount", s, e), 0);
    return steps > 0 ? round(steps / (moving.sec / 60)) : null;
  }
  if (sport === "bike") {
    const xs = (dump.samples.cyclingCadence?.values ?? [])
      .filter(([s, e, v]) => v > 0 && inSpans(moving.spans, (s + e) / 2))
      .map((x) => x[2]);
    return round(avg(xs));
  }
  return null;
}

/** Moving spans clipped to [from, to). */
function clip(spans: Span[], from: number, to: number): Span[] {
  return spans
    .map(([s, e]) => [Math.max(s, from), Math.min(e, to)] as Span)
    .filter(([s, e]) => e > s);
}

type RawLap = { kind: string; s: number; e: number };

/**
 * Watch segments come as parallel chains: Apple writes auto-splits per km AND per mile, both as
 * `segment` events; custom-workout steps are one more chain. Chains are linked end-to-start.
 */
function segmentChains(xs: RawLap[]): RawLap[][] {
  const chains: RawLap[][] = [];
  for (const x of [...xs].sort((a, b) => a.s - b.s)) {
    const chain = chains.find((c) => Math.abs(c[c.length - 1].e - x.s) < 2);
    if (chain) chain.push(x);
    else chains.push([x]);
  }
  return chains;
}

/**
 * Laps as the watch recorded them, with the same per-lap numbers as the summary. Kinds:
 * - `manual` — between markers the athlete set (Action button / double tap during the workout):
 *   [start, m1], [m1, m2], …, [mN, end]. Usually the most meaningful split (e.g. a parkrun
 *   inside a long session with warm-up and cool-down).
 * - `split_km` — automatic km splits (mile splits are dropped as a duplicate when km exist).
 * - `segment` — other segment chains (custom workout steps), `lap` — lap events (e.g. pool).
 * No matching to the plan: the coach compares these with the planned structure side by side.
 */
export function lapsOf(dump: HealthKitDump): Lap[] {
  const { sport, subSport } = sportOf(dump);
  const dk = distanceKey(sport);
  const moving = movingTime(dump, sport, subSport);
  const footSport = sport === "run" || subSport === "walk" || subSport === "hike";
  const powerKey = sport === "bike" ? "cyclingPower" : "runningPower";
  const elapsed = dump.workout.durationSec;
  const distIn = (x: RawLap) => (dump.samples[dk] ? sumIn(dump, dk, x.s, x.e) : null);

  const evs = dump.workout.events
    .map((e) => ({ kind: e.type, s: offset(dump, e.start), e: offset(dump, e.end) }));
  const markers = [
    ...new Set(
      evs.filter((x) => x.kind === "marker" && x.s > 1 && x.s < elapsed - 1).map((x) => x.s),
    ),
  ].sort((a, b) => a - b);
  const manual: RawLap[] = markers.length
    ? [0, ...markers].map((t, i) => ({ kind: "manual", s: t, e: markers[i] ?? elapsed }))
    : [];

  const segments = evs.filter((x) => x.kind === "segment" && x.e > x.s);
  const typed = segmentChains(segments).map((chain) => {
    const full = chain.slice(0, -1).map(distIn).filter((d): d is number => d !== null)
      .sort((a, b) => a - b);
    const median = full.length ? full[Math.floor(full.length / 2)] : null;
    const kind = median === null
      ? "segment"
      : Math.abs(median - 1000) < 15
      ? "split_km"
      : Math.abs(median - 1609.34) < 20
      ? "split_mile"
      : "segment";
    return chain.map((x) => ({ ...x, kind }));
  });
  const hasKm = typed.some((c) => c[0].kind === "split_km");
  const auto = typed.flat().filter((x) => !(hasKm && x.kind === "split_mile"));
  const laps = evs.filter((x) => x.kind === "lap" && x.e > x.s);
  const order = ["manual", "segment", "lap", "split_km", "split_mile"];

  return [...manual, ...auto, ...laps]
    .filter((x) => x.e > x.s)
    .sort((a, b) => order.indexOf(a.kind) - order.indexOf(b.kind) || a.s - b.s)
    .map((x, index) => {
      const spans = clip(moving.spans, x.s, x.e);
      const mv = spanSec(spans);
      const distance = distIn(x);
      const km = distance ? distance / 1000 : null;
      const hr = (dump.samples.heartRate?.values ?? [])
        .filter(([s, e]) => (s + e) / 2 >= x.s && (s + e) / 2 < x.e)
        .map((v) => v[2]);
      return {
        index,
        kind: x.kind,
        startSec: round(x.s, 1)!,
        endSec: round(x.e, 1)!,
        durationSec: round(x.e - x.s, 1)!,
        distanceM: round(distance, 1),
        movingSec: Math.round(mv),
        avgHr: round(avg(hr)),
        maxHr: hr.length ? Math.round(Math.max(...hr)) : null,
        paceSecPerKm: footSport && km && mv ? Math.round(mv / km) : null,
        speedKmh: sport === "bike" && km && mv ? round(km / (mv / 3600), 1) : null,
        powerAvg: round(meanIn(dump, powerKey, x.s, x.e)),
        cadence: cadenceAvg(dump, sport, { sec: mv, spans }),
      };
    });
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
  // Manual intervals up front: in a parkrun with warm-up through traffic lights the whole-workout
  // averages hide the effort; the coach should see the interval without opening laps.
  const intervals = lapsOf(dump).filter((l) => l.kind === "manual").map(
    ({ index: _i, kind: _k, endSec: _e, ...l }) => l,
  );
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
    /** Intervals between the athlete's markers (null when none were set). */
    intervals: intervals.length ? intervals : null,
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
        cadenceSpm: cadenceAvg(dump, sport, moving),
      }
      : undefined,
    cycling: sport === "bike"
      ? {
        powerAvg: round(avg(values(dump, "cyclingPower"))),
        powerMax: values(dump, "cyclingPower").length
          ? Math.max(...values(dump, "cyclingPower"))
          : null,
        cadenceAvg: cadenceAvg(dump, sport, moving),
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
    } else if (ch === "cadence") {
      // Run: steps per minute from step-count intervals. Bike: rpm samples.
      if (sport === "run" && dump.samples.stepCount) {
        out.cadence = out.t.map((_, i) =>
          round(sumIn(dump, "stepCount", from + i * width, from + (i + 1) * width) / (width / 60))
        );
      } else if (dump.samples.cyclingCadence) {
        out.cadence = out.t.map((_, i) =>
          round(meanIn(dump, "cyclingCadence", from + i * width, from + (i + 1) * width), 1)
        );
      }
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
