// Per-activity analysis stored with the summary (FR-MCP-9, D30): GAP, time-at-HR and time-at-power
// histograms (zones are applied at read time, so a threshold change needs no recompute), steady
// segments (for efficiency trends) and aerobic decoupling. Pure: works on a 1 Hz resampling of the
// dump. Thresholds never enter here — only the athlete's own data.
import type { HealthKitDump } from "./healthkit.ts";

type Span = [number, number];

/** Seconds per bin starting at `lo` (bin i = [lo + i·step, lo + (i+1)·step)). */
export interface Hist {
  lo: number;
  step: number;
  sec: number[];
}

/**
 * A stretch of steady aerobic state: continuously moving, HR within ±6 bpm and output (speed/GAP or
 * power) within ±20 % of the previous 5 min, for ≥ 5 min (first 2 min dropped: HR settling).
 * HR-led on purpose: an easy run by HR varies in pace with terrain, which is fine; stops and surges
 * break a segment, slow HR drift does not (that drift is what decoupling measures).
 */
export interface SteadySegment {
  startSec: number;
  durationSec: number;
  hr: number;
  /** m/s over ground. */
  speed: number | null;
  /** Grade-adjusted m/s (run with altitude), else null. */
  gapSpeed: number | null;
  power: number | null;
  /** Mean absolute grade, % (run with altitude). */
  gradePct: number | null;
}

export interface Decoupling {
  /** (EF first half − EF second half) / EF first half, %. Positive = HR drifted up for the same output. */
  pct: number;
  metric: "pace" | "power";
  steadyMin: number;
  basis: string;
}

export interface Analysis {
  /** Grade-adjusted pace over moving time (run with altitude). */
  gapSecPerKm: number | null;
  gapBasis: string | null;
  /** Time at each bpm while moving (1-bpm bins). */
  hrHist: Hist | null;
  /** Time at power while moving (5-W bins, zeros = coasting count). */
  powerHist: Hist | null;
  steady: SteadySegment[];
  decoupling: Decoupling | null;
}

export interface AnalysisInput {
  sport: string;
  subSport: string | null;
  /** Moving spans (same definition as moving time / pace). */
  moving: Span[];
  distanceKey: string;
}

const MAX_SEC = 16 * 3600;
const STEADY_BLOCK = 60;
const STEADY_MIN_BLOCKS = 7; // 7 min of even output, of which the first 2 are dropped
const STEADY_DROP = 2;
const STEADY_HR_BPM = 6;
const STEADY_OUTPUT = 0.2;
const STEADY_REF_BLOCKS = 5;
const DECOUPLING_MIN_SEC = 40 * 60;

/** Minetti et al. 2002: energy cost of running on grade i (fraction), J/kg/m. */
export function minettiCost(i: number): number {
  const g = Math.max(-0.45, Math.min(0.45, i));
  return 155.4 * g ** 5 - 30.4 * g ** 4 - 43.3 * g ** 3 + 46.3 * g ** 2 + 19.5 * g + 3.6;
}

/** Instantaneous samples → 1 Hz values, linear between samples closer than `maxGap` seconds. */
function fillPoints(
  values: [number, number, number][] | undefined,
  n: number,
  maxGap: number,
): Float64Array {
  const out = new Float64Array(n).fill(NaN);
  if (!values?.length) return out;
  const pts = values.map(([s, e, v]) => [(s + e) / 2, v] as [number, number])
    .filter(([t, v]) => Number.isFinite(t) && Number.isFinite(v))
    .sort((a, b) => a[0] - b[0]);
  for (let k = 0; k < pts.length; k++) {
    const [t0, v0] = pts[k];
    const next = pts[k + 1];
    if (next && next[0] - t0 <= maxGap && next[0] > t0) {
      const [t1, v1] = next;
      for (let t = Math.max(0, Math.ceil(t0)); t < Math.min(n, Math.ceil(t1)); t++) {
        out[t] = v0 + (v1 - v0) * (t - t0) / (t1 - t0);
      }
    } else {
      // Last point of a run: hold briefly.
      for (let t = Math.max(0, Math.ceil(t0)); t < Math.min(n, Math.ceil(t0 + 5)); t++) {
        if (Number.isNaN(out[t])) out[t] = v0;
      }
    }
  }
  return out;
}

/** Interval samples (distance per [s, e)) → metres per second slot, prorated. */
function spreadIntervals(values: [number, number, number][] | undefined, n: number): Float64Array {
  const out = new Float64Array(n);
  for (const [s, e, v] of values ?? []) {
    if (!(e > s) || !Number.isFinite(v)) continue;
    const rate = v / (e - s);
    for (let t = Math.max(0, Math.floor(s)); t < Math.min(n, Math.ceil(e)); t++) {
      const overlap = Math.min(e, t + 1) - Math.max(s, t);
      if (overlap > 0) out[t] += rate * overlap;
    }
  }
  return out;
}

function movingMask(spans: Span[], n: number): Uint8Array {
  const m = new Uint8Array(n);
  for (const [s, e] of spans) {
    for (let t = Math.max(0, Math.ceil(s)); t < Math.min(n, Math.ceil(e)); t++) m[t] = 1;
  }
  return m;
}

/** Centered moving average ignoring NaN (window = 2·half + 1). */
function smooth(xs: Float64Array, half: number): Float64Array {
  const n = xs.length;
  const sum = new Float64Array(n + 1);
  const cnt = new Float64Array(n + 1);
  for (let i = 0; i < n; i++) {
    const ok = !Number.isNaN(xs[i]);
    sum[i + 1] = sum[i] + (ok ? xs[i] : 0);
    cnt[i + 1] = cnt[i] + (ok ? 1 : 0);
  }
  const out = new Float64Array(n).fill(NaN);
  for (let i = 0; i < n; i++) {
    const a = Math.max(0, i - half);
    const b = Math.min(n, i + half + 1);
    const c = cnt[b] - cnt[a];
    if (c > 0) out[i] = (sum[b] - sum[a]) / c;
  }
  return out;
}

function hist(xs: Float64Array, mask: Uint8Array, step: number): Hist | null {
  const bins = new Map<number, number>();
  for (let t = 0; t < xs.length; t++) {
    if (!mask[t] || Number.isNaN(xs[t]) || xs[t] < 0) continue;
    const b = Math.floor(xs[t] / step);
    bins.set(b, (bins.get(b) ?? 0) + 1);
  }
  if (bins.size === 0) return null;
  const keys = [...bins.keys()];
  const lo = Math.min(...keys);
  const hi = Math.max(...keys);
  const sec = Array.from({ length: hi - lo + 1 }, (_, i) => bins.get(lo + i) ?? 0);
  return { lo: lo * step, step, sec };
}

const r = (x: number, d = 0) => Math.round(x * 10 ** d) / 10 ** d;
const mean = (xs: number[]) => xs.reduce((a, b) => a + b, 0) / xs.length;

export function analyze(dump: HealthKitDump, inp: AnalysisInput): Analysis {
  const n = Math.min(Math.ceil(dump.workout.durationSec), MAX_SEC);
  const none: Analysis = {
    gapSecPerKm: null,
    gapBasis: null,
    hrHist: null,
    powerHist: null,
    steady: [],
    decoupling: null,
  };
  if (n < 60) return none;
  const foot = inp.sport === "run" || inp.subSport === "walk" || inp.subSport === "hike";
  const bike = inp.sport === "bike";
  const mask = movingMask(inp.moving, n);
  const hr = fillPoints(dump.samples.heartRate?.values, n, 30);
  const powerKey = bike ? "cyclingPower" : "runningPower";
  const power = fillPoints(dump.samples[powerKey]?.values, n, 10);
  const hasPower = power.some((x) => !Number.isNaN(x));
  const dist = spreadIntervals(dump.samples[inp.distanceKey]?.values, n);
  const hasDist = (dump.samples[inp.distanceKey]?.values.length ?? 0) >= 10 &&
    inp.subSport !== "indoor_bike";

  // Speed: 15-s centered window over metres per second.
  const speed = hasDist ? smooth(dist.map((d, t) => (mask[t] ? d : NaN)), 7) : null;

  // Grade from route altitude (run outdoors): altitude smoothed over 15 s, grade over ±15 s.
  let factor: Float64Array | null = null;
  let gradeAbs: Float64Array | null = null;
  const altPts = dump.route.filter((p) => p.length > 3 && Number.isFinite(p[3]));
  if (foot && hasDist && inp.subSport !== "treadmill" && altPts.length >= 60) {
    const alt = smooth(
      fillPoints(altPts.map((p) => [p[0], p[0], p[3]] as [number, number, number]), n, 30),
      7,
    );
    const cum = new Float64Array(n + 1);
    for (let t = 0; t < n; t++) cum[t + 1] = cum[t] + dist[t];
    factor = new Float64Array(n).fill(1);
    gradeAbs = new Float64Array(n).fill(NaN);
    const c0 = minettiCost(0);
    for (let t = 0; t < n; t++) {
      const a = Math.max(0, t - 15);
      const b = Math.min(n - 1, t + 15);
      const d = cum[b + 1] - cum[a];
      if (d < 20 || Number.isNaN(alt[a]) || Number.isNaN(alt[b])) continue;
      const g = Math.max(-0.3, Math.min(0.3, (alt[b] - alt[a]) / d));
      factor[t] = minettiCost(g) / c0;
      gradeAbs[t] = Math.abs(g);
    }
  }

  // GAP over moving time: equivalent flat distance.
  let gapSecPerKm: number | null = null;
  let movingSec = 0;
  let flat = 0;
  if (factor) {
    for (let t = 0; t < n; t++) {
      if (!mask[t]) continue;
      movingSec++;
      flat += dist[t] * factor[t];
    }
    if (flat > 500) gapSecPerKm = Math.round(movingSec / (flat / 1000));
  }

  // Steady segments over 60-s blocks.
  const output = (t: number): number => {
    if (bike) return hasPower ? power[t] : NaN; // outdoor bike speed is wind and grade: power only
    if (!foot || !speed) return NaN;
    return factor ? speed[t] * factor[t] : speed[t];
  };
  interface Block {
    i: number;
    hr: number;
    out: number;
    speed: number | null;
    gap: number | null;
    power: number | null;
    grade: number | null;
  }
  const blocks: (Block | null)[] = [];
  for (let i = 0; (i + 1) * STEADY_BLOCK <= n; i++) {
    const hs: number[] = [];
    const os: number[] = [];
    const ss: number[] = [];
    const gs: number[] = [];
    const ps: number[] = [];
    const gr: number[] = [];
    let mv = 0;
    for (let t = i * STEADY_BLOCK; t < (i + 1) * STEADY_BLOCK; t++) {
      if (!mask[t]) continue;
      mv++;
      if (!Number.isNaN(hr[t])) hs.push(hr[t]);
      const o = output(t);
      if (!Number.isNaN(o)) os.push(o);
      if (speed && !Number.isNaN(speed[t])) ss.push(speed[t]);
      if (factor && speed && !Number.isNaN(speed[t])) gs.push(speed[t] * factor[t]);
      if (!Number.isNaN(power[t])) ps.push(power[t]);
      if (gradeAbs && !Number.isNaN(gradeAbs[t])) gr.push(gradeAbs[t]);
    }
    const ok = mv >= STEADY_BLOCK - 5 && hs.length >= 45 && os.length >= 45 && mean(os) > 0;
    blocks.push(
      ok
        ? {
          i,
          hr: mean(hs),
          out: mean(os),
          speed: ss.length ? mean(ss) : null,
          gap: gs.length ? mean(gs) : null,
          power: ps.length ? mean(ps) : null,
          grade: gr.length ? mean(gr) : null,
        }
        : null,
    );
  }
  const runs: Block[][] = [];
  let cur: Block[] = [];
  const flush = () => {
    if (cur.length >= STEADY_MIN_BLOCKS) runs.push(cur.slice(STEADY_DROP));
    cur = [];
  };
  for (const b of blocks) {
    if (!b) {
      flush();
      continue;
    }
    if (cur.length) {
      const last = cur.slice(-STEADY_REF_BLOCKS);
      const refHr = mean(last.map((x) => x.hr));
      const refOut = mean(last.map((x) => x.out));
      if (
        Math.abs(b.hr - refHr) > STEADY_HR_BPM || Math.abs(b.out - refOut) / refOut > STEADY_OUTPUT
      ) {
        flush();
      }
    }
    cur.push(b);
  }
  flush();
  const steadyBlocks = runs.flat();
  const avgOf = (bs: Block[], k: "speed" | "gap" | "power" | "grade") => {
    const xs = bs.map((b) => b[k]).filter((x): x is number => x !== null);
    return xs.length === bs.length ? mean(xs) : null;
  };
  const steady: SteadySegment[] = runs.map((bs) => ({
    startSec: bs[0].i * STEADY_BLOCK,
    durationSec: bs.length * STEADY_BLOCK,
    hr: r(mean(bs.map((b) => b.hr)), 1),
    speed: avgOf(bs, "speed") === null ? null : r(avgOf(bs, "speed")!, 3),
    gapSpeed: avgOf(bs, "gap") === null ? null : r(avgOf(bs, "gap")!, 3),
    power: avgOf(bs, "power") === null ? null : r(avgOf(bs, "power")!),
    gradePct: avgOf(bs, "grade") === null ? null : r(avgOf(bs, "grade")! * 100, 1),
  }));

  // Decoupling over steady time only (Friel's Pa:HR / Pw:HR): halves by steady time.
  let decoupling: Decoupling | null = null;
  if (steadyBlocks.length * STEADY_BLOCK >= DECOUPLING_MIN_SEC) {
    const half = Math.floor(steadyBlocks.length / 2);
    const ef = (bs: Block[]) => mean(bs.map((b) => b.out)) / mean(bs.map((b) => b.hr));
    const a = ef(steadyBlocks.slice(0, half));
    const b = ef(steadyBlocks.slice(half));
    const metric = bike ? "power" : "pace";
    decoupling = {
      pct: r((a - b) / a * 100, 1),
      metric,
      steadyMin: Math.round(steadyBlocks.length * STEADY_BLOCK / 60),
      basis:
        `${metric === "power" ? "power" : factor ? "grade-adjusted speed" : "speed"} per bpm, ` +
        "first vs second half of steady segments (HR ±6 bpm, output ±20 %, ≥5 min)",
    };
  }

  return {
    gapSecPerKm,
    gapBasis: gapSecPerKm === null
      ? null
      : "Minetti 2002 energy cost of grade; altitude from the route (GPS/barometer), grade over ±15 s",
    hrHist: hist(hr, mask, 1),
    powerHist: hasPower && (bike || foot) ? hist(power, mask, 5) : null,
    steady,
    decoupling,
  };
}

/** The analysis stored in an activity summary, or null (manual entry, older summary version). */
export function analysisOf(summary: Record<string, unknown>): Analysis | null {
  const a = summary.analysis as Analysis | undefined;
  return a && typeof a === "object" && Array.isArray(a.steady) ? a : null;
}
