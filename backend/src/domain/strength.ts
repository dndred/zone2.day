// Strength log analysis (pure): e1RM, compact set notation, exercise progression.
import type { Load, StrengthSession, StrengthSet } from "../db/strength.ts";

/** Epley estimate, only for 1–12 reps with a weight (beyond that it is meaningless). */
export function e1rm(l: Load | null | undefined): number | null {
  if (!l?.weightKg || !l.reps || l.reps < 1 || l.reps > 12) return null;
  return Math.round(l.weightKg * (1 + l.reps / 30) * 10) / 10;
}

/** "60×8", "×12" (bodyweight), "45 s", "20 × 40 m", "—" (not done). */
export function fmt(l: Load | null | undefined): string {
  if (!l) return "—";
  let out = l.weightKg ? `${l.weightKg}` : "";
  if (l.reps) out += `×${l.reps}`;
  for (const extra of [l.holdSec ? `${l.holdSec} s` : "", l.distanceM ? `${l.distanceM} m` : ""]) {
    if (extra) out = out ? `${out} × ${extra}` : extra;
  }
  if (l.weightKg && !l.reps && !l.holdSec && !l.distanceM) out = `${l.weightKg} kg`;
  return out || "✓";
}

const norm = (s: string) => s.trim().toLowerCase();

/** Log of sessions grouped by exercise: plan vs fact per set, misses marked. */
export function logView(s: StrengthSession) {
  const byExercise = new Map<string, StrengthSet[]>();
  for (const set of [...s.sets].sort((a, b) => a.order - b.order || a.setIndex - b.setIndex)) {
    byExercise.set(set.exercise, [...(byExercise.get(set.exercise) ?? []), set]);
  }
  return {
    sessionId: s.id,
    date: s.date,
    plannedWorkoutId: s.plannedWorkoutId ?? undefined,
    source: s.source,
    notes: s.notes ?? undefined,
    exercises: [...byExercise].map(([exercise, sets]) => ({
      exercise,
      sets: sets.map((x) => ({
        id: x.id,
        planned: x.planned ? fmt(x.planned) : undefined,
        actual: fmt(x.actual),
        rpe: x.rpe ?? undefined,
        note: x.note ?? undefined,
      })),
      missed: sets.filter((x) => x.planned && !x.actual).length || undefined,
    })),
  };
}

/** Progression of one exercise over sessions (newest first). */
export function exerciseHistory(sessions: StrengthSession[], names: string[]) {
  const wanted = new Set(names.map(norm));
  const rows = sessions
    .map((s) => {
      const sets = s.sets.filter((x) => wanted.has(norm(x.exercise)) && x.actual);
      if (!sets.length) return null;
      const best = sets.reduce((a, b) =>
        (e1rm(b.actual) ?? b.actual?.weightKg ?? 0) > (e1rm(a.actual) ?? a.actual?.weightKg ?? 0)
          ? b
          : a
      );
      const rpes = sets.map((x) => x.rpe).filter((x): x is number => x !== null);
      const planned = sets.filter((x) => x.planned);
      return {
        date: s.date,
        sets: sets.map((x) => fmt(x.actual)).join(", "),
        best: fmt(best.actual),
        e1rmKg: e1rm(best.actual) ?? undefined,
        rpeAvg: rpes.length
          ? Math.round(rpes.reduce((a, b) => a + b, 0) / rpes.length * 10) / 10
          : undefined,
        vsPlan: planned.length
          ? planned.every((x) =>
              (x.actual?.weightKg ?? 0) >= (x.planned?.weightKg ?? 0) &&
              (x.actual?.reps ?? 0) >= (x.planned?.reps ?? 0)
            )
            ? "as planned or more"
            : "below plan"
          : undefined,
      };
    })
    .filter((r): r is NonNullable<typeof r> => r !== null)
    .sort((a, b) => b.date.localeCompare(a.date));
  const gaps = rows.slice(0, -1).map((r, i) =>
    Math.round((Date.parse(r.date) - Date.parse(rows[i + 1].date)) / 86_400_000)
  );
  return { sessions: rows, gapsDays: gaps.length ? gaps : undefined };
}
