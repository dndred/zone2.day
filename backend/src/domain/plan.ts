// Target resolution and rough estimates for planned workouts. Pure functions.
import type { Profile, Threshold } from "./entities.ts";
import { EnduranceStructure, flattenSteps, type Step, type Target } from "./structure.ts";

export type SportKind = "run" | "bike" | "swim" | "strength" | "other";

export interface ResolvedTarget {
  metric: Target["metric"];
  low?: number;
  high?: number;
  unit: "abs";
  /** Set when a %-target could not be resolved (missing threshold). */
  unresolved?: string;
  basis?: string;
}

const mid = (t: Threshold): number => (typeof t === "number" ? t : (t.low + t.high) / 2);
const describe = (t: Threshold): string =>
  typeof t === "number" ? String(t) : `${t.low}–${t.high} (mid)`;

function thresholdFor(
  metric: Target["metric"],
  sport: SportKind,
  p: Profile,
): { value: Threshold; name: string } | null {
  const pick = (v: Threshold | null | undefined, name: string) => (v ? { value: v, name } : null);
  if (metric === "hr") {
    return sport === "bike" ? pick(p.bike?.lthr, "bike.lthr") : pick(p.run?.lthr, "run.lthr");
  }
  if (metric === "power" && sport === "bike") return pick(p.bike?.ftp, "bike.ftp");
  if (metric === "pace" && sport === "run") {
    return pick(p.run?.thresholdPaceSecPerKm, "run.thresholdPaceSecPerKm");
  }
  if (metric === "pace" && sport === "swim") return pick(p.swim?.cssSecPer100m, "swim.css");
  return null;
}

export function resolveTarget(t: Target, sport: SportKind, profile: Profile): ResolvedTarget {
  if (t.unit === "abs") return { metric: t.metric, low: t.low, high: t.high, unit: "abs" };
  const th = thresholdFor(t.metric, sport, profile);
  if (!th) {
    return { metric: t.metric, unit: "abs", unresolved: `no threshold for ${t.metric}/${sport}` };
  }
  const base = mid(th.value);
  // Pace is "slower when lower %": pace = threshold / (pct/100). Everything else scales directly.
  const conv = (pct?: number) =>
    pct === undefined
      ? undefined
      : t.metric === "pace"
      ? Math.round(base / (pct / 100))
      : Math.round(base * pct / 100);
  const a = conv(t.low);
  const b = conv(t.high);
  const [low, high] = t.metric === "pace" ? [b, a] : [a, b]; // faster pace = smaller number
  return {
    metric: t.metric,
    low,
    high,
    unit: "abs",
    basis: `${th.name} ${describe(th.value)}`,
  };
}

export interface Estimate {
  durationSec: number | null;
  distanceM: number | null;
  /** Steps whose length could not be estimated (open without estimateSec, distance without pace). */
  unknownSteps: number;
  basis: string[];
}

function paceSecPerMeter(step: Step, sport: SportKind, profile: Profile): number | null {
  const targets = [step.target, ...(step.secondary ?? [])].filter(Boolean) as Target[];
  const pace = targets.find((t) => t.metric === "pace");
  if (!pace) return null;
  const r = resolveTarget(pace, sport, profile);
  const lo = r.low ?? r.high;
  const hi = r.high ?? r.low;
  if (lo === undefined || hi === undefined) return null;
  const perUnit = (lo + hi) / 2;
  return sport === "swim" ? perUnit / 100 : perUnit / 1000;
}

/**
 * Sums time steps, converts distance↔time through pace targets where possible.
 * Without thresholds this stays partial on purpose: history-based estimates come with activities.
 */
export function estimate(structure: unknown, sport: SportKind, profile: Profile): Estimate {
  const parsed = EnduranceStructure.safeParse(structure);
  if (!parsed.success) return { durationSec: null, distanceM: null, unknownSteps: 0, basis: [] };
  let sec = 0;
  let meters = 0;
  let unknown = 0;
  let distanceKnown = true;
  const basis = new Set<string>();
  for (const step of flattenSteps(parsed.data)) {
    const pace = paceSecPerMeter(step, sport, profile);
    const d = step.duration;
    if (d.type === "time") {
      sec += d.sec;
      if (pace) meters += d.sec / pace;
      else distanceKnown = false;
    } else if (d.type === "distance") {
      meters += d.m;
      if (pace) {
        sec += d.m * pace;
        basis.add("distance→time via pace target");
      } else unknown++;
    } else {
      if (d.estimateSec) {
        sec += d.estimateSec;
        basis.add("open steps via estimateSec");
      } else unknown++;
      distanceKnown = false;
    }
  }
  return {
    durationSec: Math.round(sec) || null,
    distanceM: distanceKnown && meters > 0 ? Math.round(meters) : null,
    unknownSteps: unknown,
    basis: [...basis],
  };
}

/** Copy of the structure with every target resolved to absolute values for devices. */
export function resolveStructure(structure: unknown, sport: SportKind, profile: Profile): unknown {
  const parsed = EnduranceStructure.safeParse(structure);
  if (!parsed.success) return structure;
  const fix = (s: Step) => ({
    ...s,
    target: s.target ? resolveTarget(s.target, sport, profile) : undefined,
    secondary: s.secondary?.map((t) => resolveTarget(t, sport, profile)),
  });
  return {
    ...parsed.data,
    steps: parsed.data.steps.map((n) =>
      n.type === "step" ? fix(n) : { ...n, steps: n.steps.map(fix) }
    ),
  };
}

/** %-of-threshold targets that cannot be resolved with the current profile (they won't reach the watch). */
export function unresolvedTargets(
  structure: unknown,
  sport: SportKind,
  profile: Profile,
): { stepId: string; metric: string; message: string }[] {
  const parsed = EnduranceStructure.safeParse(structure);
  if (!parsed.success) return [];
  const out: { stepId: string; metric: string; message: string }[] = [];
  const seen = new Set<string>();
  for (const s of flattenSteps(parsed.data)) {
    for (const t of [s.target, ...(s.secondary ?? [])]) {
      if (!t || t.unit !== "pct_threshold" || seen.has(`${s.id}:${t.metric}`)) continue;
      const r = resolveTarget(t, sport, profile);
      if (r.unresolved) {
        seen.add(`${s.id}:${t.metric}`);
        out.push({
          stepId: s.id,
          metric: t.metric,
          message:
            `${r.unresolved}: this target will not be sent to the watch until the threshold is set (update_profile) or the target is given in absolute units`,
        });
      }
    }
  }
  return out;
}

/** done = an activity is matched; missed = date passed without one; skipped = AI said so. */
export function workoutStatus(
  w: { date: string; skipped?: unknown },
  matched: boolean,
  today: string,
): "done" | "skipped" | "missed" | "planned" {
  if (matched) return "done";
  if (w.skipped) return "skipped";
  return w.date < today ? "missed" : "planned";
}

/** True when a bike workout has power targets (only then .zwo makes sense). */
export function hasPowerTargets(structure: unknown): boolean {
  const parsed = EnduranceStructure.safeParse(structure);
  if (!parsed.success) return false;
  return flattenSteps(parsed.data).some((s) =>
    [s.target, ...(s.secondary ?? [])].some((t) => t?.metric === "power")
  );
}
