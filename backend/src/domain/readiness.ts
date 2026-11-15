// Daily health metrics against the athlete's own baseline (docs/04-mcp.md §3.7). Pure.
// Baseline = the 28 days before the date (the date itself excluded), needs ≥ 14 values.
import { addDays } from "./time.ts";

export interface Sleep {
  asleepMin: number;
  deepMin?: number | null;
  remMin?: number | null;
  coreMin?: number | null;
  awakeMin?: number | null;
  inBedStart?: string | null;
  inBedEnd?: string | null;
  source?: string | null;
}

export interface DailyMetrics {
  date: string;
  restingHr: number | null;
  hrvSdnnMs: number | null;
  hrvSamples: number | null;
  sleep: Sleep | null;
  respiratoryRate: number | null;
  wristTempC: number | null;
  weightKg: number | null;
  vo2max: number | null;
}

export const BASELINE_DAYS = 28;
const MIN_BASELINE = 14;

export interface Baseline {
  mean: number;
  sd: number;
  n: number;
}

export interface Compared {
  value: number;
  /** Mean of the 7 days ending at this date (incl.), smooths Apple's noisy HRV. */
  avg7: number | null;
  baseline: number | null;
  delta: number | null;
  /** (value − baseline mean) / sd; null without a baseline. */
  z: number | null;
}

const r1 = (x: number) => Math.round(x * 10) / 10;
const r2 = (x: number) => Math.round(x * 100) / 100;

export function baselineOf(xs: number[]): Baseline | null {
  if (xs.length < MIN_BASELINE) return null;
  const mean = xs.reduce((a, b) => a + b, 0) / xs.length;
  const sd = Math.sqrt(xs.reduce((a, b) => a + (b - mean) ** 2, 0) / (xs.length - 1));
  return { mean, sd, n: xs.length };
}

type Key = "restingHr" | "hrvSdnnMs" | "respiratoryRate" | "wristTempC" | "asleepMin";

const valueOf = (d: DailyMetrics | undefined, k: Key): number | null =>
  !d ? null : k === "asleepMin" ? (d.sleep?.asleepMin ?? null) : d[k];

/**
 * Days in [from, to] with each metric compared to its baseline, plus flags. `all` must cover
 * from − 28 … to (oldest first or any order).
 */
export function compareDays(all: DailyMetrics[], from: string, to: string) {
  const byDate = new Map(all.map((d) => [d.date, d]));
  const series = (k: Key, end: string, days: number) => {
    const out: number[] = [];
    for (let i = 1; i <= days; i++) {
      const v = valueOf(byDate.get(addDays(end, -i)), k);
      if (v !== null && Number.isFinite(v)) out.push(v);
    }
    return out;
  };
  const compare = (k: Key, date: string, digits = 1): Compared | null => {
    const v = valueOf(byDate.get(date), k);
    if (v === null) return null;
    const base = baselineOf(series(k, date, BASELINE_DAYS));
    const last7 = [v, ...series(k, date, 6)];
    const round = digits === 2 ? r2 : r1;
    return {
      value: round(v),
      avg7: last7.length >= 4 ? round(last7.reduce((a, b) => a + b, 0) / last7.length) : null,
      baseline: base ? round(base.mean) : null,
      delta: base ? round(v - base.mean) : null,
      z: base && base.sd > 0 ? r1((v - base.mean) / base.sd) : null,
    };
  };

  const days = [];
  for (let date = from; date <= to; date = addDays(date, 1)) {
    const d = byDate.get(date);
    if (!d) {
      days.push({ date, missing: true as const });
      continue;
    }
    const restingHr = compare("restingHr", date);
    const hrv = compare("hrvSdnnMs", date);
    const resp = compare("respiratoryRate", date);
    const temp = compare("wristTempC", date, 2);
    const sleep = compare("asleepMin", date);
    const flags: string[] = [];
    // HRV: the 7-day mean below the baseline by > 1 sd is the signal; one low morning is noise.
    const hrvBase = baselineOf(series("hrvSdnnMs", date, BASELINE_DAYS));
    if (hrv?.avg7 && hrvBase && hrv.avg7 < hrvBase.mean - hrvBase.sd) flags.push("hrv_7d_low");
    if (hrv?.z !== null && hrv?.z !== undefined && hrv.z <= -2) flags.push("hrv_very_low_today");
    if (restingHr?.delta !== null && restingHr?.delta !== undefined && restingHr.delta >= 5) {
      flags.push("resting_hr_up");
    }
    if (temp?.delta !== null && temp?.delta !== undefined && temp.delta >= 0.5) {
      flags.push("wrist_temp_up");
    }
    if (resp?.delta !== null && resp?.delta !== undefined && resp.delta >= 1.5) {
      flags.push("respiratory_rate_up");
    }
    if (d.sleep && d.sleep.asleepMin < 360) flags.push("short_sleep");
    days.push({
      date,
      restingHr,
      hrvSdnnMs: hrv,
      hrvSamples: d.hrvSamples ?? undefined,
      sleep: d.sleep
        ? {
          ...d.sleep,
          vsBaselineMin: sleep?.delta ?? null,
        }
        : null,
      respiratoryRate: resp,
      wristTempC: temp,
      weightKg: d.weightKg,
      vo2max: d.vo2max,
      flags,
    });
  }
  return days;
}
