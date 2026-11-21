// Plan-like entities stored as JSONB documents (D35). Zod is the schema; the DB only stores it.
import { z } from "zod";
import { EnduranceStructure, StrengthStructure } from "./structure.ts";
import type { EnduranceStructure as EnduranceStructureT } from "./structure.ts";
import { isValidDate, isValidTimeZone } from "./time.ts";

export const IsoDate = z.string().refine(isValidDate, { message: "expected date YYYY-MM-DD" });
export const TimeZone = z.string().refine(isValidTimeZone, { message: "unknown IANA time zone" });
const Slug = z.string().regex(/^[a-z0-9][a-z0-9-]{0,47}$/, "slug: lowercase letters, digits, '-'");
const NotebookRefs = z.array(Slug).max(10).default([]);

// ---------------- profile ----------------

/** A threshold is a number or a range with its basis (e.g. LTHR 156–162 from 8–10′ reps). */
export const Threshold = z.union([
  z.number().positive(),
  z.object({
    low: z.number().positive(),
    high: z.number().positive(),
    basis: z.string().max(300).optional(),
  }),
]);
export type Threshold = z.infer<typeof Threshold>;

export const Travel = z.object({
  from: IsoDate,
  to: IsoDate,
  timezone: TimeZone,
  note: z.string().max(120).optional(),
}).refine((t) => t.from <= t.to, { message: "travel.from must be ≤ travel.to" });

const Zones = z.array(z.number().nonnegative()).max(8);

const RunProfile = z.looseObject({
  thresholdPaceSecPerKm: Threshold.nullable().optional(),
  lthr: Threshold.nullable().optional(),
  maxHr: z.number().positive().optional(),
  restingHr: z.number().positive().optional(),
  hrZones: Zones.optional(),
  paceZones: Zones.optional(),
});
const BikeProfile = z.looseObject({
  ftp: Threshold.nullable().optional(),
  mywhooshFtp: z.number().positive().optional(),
  lthr: Threshold.nullable().optional(),
  maxHr: z.number().positive().optional(),
  powerZones: Zones.optional(),
  hrZones: Zones.optional(),
});
const SwimProfile = z.looseObject({
  cssSecPer100m: Threshold.nullable().optional(),
  poolLengthDefaultM: z.number().positive().optional(),
});
const ZoneModel = z.looseObject({
  hr: z.string().optional(),
  pace: z.string().optional(),
  power: z.string().optional(),
});

// Loose: profiles written before a key was renamed still load. New writes are checked with
// unknownProfileKeys, so a misspelled key cannot be saved and silently ignored.
export const Profile = z.looseObject({
  timezone: TimeZone.default("UTC"),
  travel: z.array(Travel).max(50).default([]),
  locale: z.string().max(10).default("en"),
  birthYear: z.number().int().min(1900).max(2100).optional(),
  sex: z.enum(["m", "f"]).optional(),
  heightCm: z.number().positive().optional(),
  weightKg: z.number().positive().optional(),
  run: RunProfile.default({}),
  bike: BikeProfile.default({}),
  swim: SwimProfile.default({}),
  zoneModel: ZoneModel.default({}),
  equipment: z.record(z.string(), z.unknown()).default({}),
  hrGuard: z.record(z.string(), z.unknown()).optional(),
});
export type Profile = z.infer<typeof Profile>;

export const DEFAULT_PROFILE: Profile = Profile.parse({});

const PROFILE_SECTIONS: Record<string, string[]> = {
  run: Object.keys(RunProfile.shape),
  bike: Object.keys(BikeProfile.shape),
  swim: Object.keys(SwimProfile.shape),
  zoneModel: Object.keys(ZoneModel.shape),
};
const PROFILE_KEYS = Object.keys(Profile.shape);

/**
 * Keys of an update_profile patch that the profile does not know (e.g. run.thresholdPace),
 * with the closest known key as a suggestion. `null` values are allowed anywhere: they remove
 * a key, including stray ones saved earlier.
 */
export function unknownProfileKeys(
  patch: Record<string, unknown>,
): { path: string; suggestion?: string }[] {
  const out: { path: string; suggestion?: string }[] = [];
  const check = (prefix: string, key: string, known: string[], value: unknown) => {
    if (known.includes(key) || value === null) return;
    out.push({ path: prefix + key, suggestion: closest(key, known) });
  };
  for (const [k, v] of Object.entries(patch)) {
    check("", k, PROFILE_KEYS, v);
    const section = PROFILE_SECTIONS[k];
    if (section && v && typeof v === "object" && !Array.isArray(v)) {
      for (const [kk, vv] of Object.entries(v)) check(`${k}.`, kk, section, vv);
    }
  }
  return out;
}

function closest(key: string, known: string[]): string | undefined {
  const k = key.toLowerCase();
  const prefixed = known.find((x) =>
    x.toLowerCase().startsWith(k) || k.startsWith(x.toLowerCase())
  );
  if (prefixed) return prefixed;
  let best: { key: string; d: number } | undefined;
  for (const x of known) {
    const d = editDistance(k, x.toLowerCase());
    if (!best || d < best.d) best = { key: x, d };
  }
  return best && best.d <= Math.max(2, Math.floor(k.length / 3)) ? best.key : undefined;
}

function editDistance(a: string, b: string): number {
  let prev = Array.from({ length: b.length + 1 }, (_, j) => j);
  for (let i = 1; i <= a.length; i++) {
    const cur = [i];
    for (let j = 1; j <= b.length; j++) {
      cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    }
    prev = cur;
  }
  return prev[b.length];
}

// ---------------- week ----------------

export const Week = z.object({
  weekStart: IsoDate.refine((d) => new Date(`${d}T00:00:00Z`).getUTCDay() === 1, {
    message: "weekStart must be a Monday",
  }),
  title: z.string().max(80).optional(),
  header: z.string().max(4000).optional(),
  review: z.string().max(4000).optional(),
  notebookRefs: NotebookRefs,
});
export type Week = z.infer<typeof Week>;

// ---------------- planned workout ----------------

export const Sport = z.enum(["run", "bike", "swim", "strength", "other"]);
export const Execution = z.enum(["workoutkit", "zone2_watch", "mywhoosh", "none"]);

export const PlannedWorkout = z.object({
  id: z.uuid(),
  date: IsoDate,
  order: z.number().int().min(0).max(20),
  sport: Sport,
  subSport: z.string().max(30).optional(),
  title: z.string().min(1).max(80),
  goal: z.string().max(140).optional(),
  notes: z.string().max(1000).optional(),
  key: z.boolean().default(false),
  tags: z.array(z.string().min(1).max(30)).max(10).default([]),
  notebookRefs: NotebookRefs,
  execution: Execution,
  structure: z.unknown().optional(),
  skipped: z.object({ reason: z.string().min(1).max(200), at: z.string() }).nullable().optional(),
}).superRefine((w, ctx) => {
  if (!EXECUTION_BY_SPORT[w.sport].includes(w.execution)) {
    ctx.addIssue({
      code: "custom",
      path: ["execution"],
      message: `execution '${w.execution}' is not valid for ${w.sport}; allowed: ${
        EXECUTION_BY_SPORT[w.sport].join(", ")
      }`,
    });
  }
  if (w.structure === undefined || w.structure === null) return;
  const schema = w.sport === "strength"
    ? StrengthStructure
    : w.sport === "other"
    ? null
    : EnduranceStructure;
  if (!schema) {
    ctx.addIssue({
      code: "custom",
      path: ["structure"],
      message: "sport 'other' has no structure",
    });
    return;
  }
  const r = schema.safeParse(w.structure);
  if (!r.success) {
    for (const issue of r.error.issues) {
      ctx.addIssue({ code: "custom", path: ["structure", ...issue.path], message: issue.message });
    }
    return;
  }
  if (schema === EnduranceStructure) {
    const allowed: readonly string[] = METRICS_BY_SPORT[w.sport as "run" | "bike" | "swim"];
    (r.data as EnduranceStructureT).steps.forEach((node, i) => {
      const steps = node.type === "step" ? [[node, ["steps", i]] as const] : node.steps.map(
        (s, j) => [s, ["steps", i, "steps", j]] as const,
      );
      for (const [step, path] of steps) {
        [step.target, ...(step.secondary ?? [])].forEach((t, k) => {
          if (t && !allowed.includes(t.metric)) {
            ctx.addIssue({
              code: "custom",
              path: ["structure", ...path, k === 0 ? "target" : `secondary`, "metric"],
              message: `metric '${t.metric}' does not apply to ${w.sport}; allowed: ${
                allowed.join(", ")
              }`,
            });
          }
        });
      }
    });
  }
});

/** Which device can execute what (docs/06-watch.md §1). */
export const EXECUTION_BY_SPORT: Record<z.infer<typeof Sport>, string[]> = {
  run: ["workoutkit", "zone2_watch", "none"],
  bike: ["workoutkit", "zone2_watch", "mywhoosh", "none"],
  swim: ["workoutkit", "zone2_watch", "none"],
  strength: ["none"],
  other: ["none"],
};

/** Target metrics that make sense per sport (Apple Watch measures running power; no power in water). */
export const METRICS_BY_SPORT = {
  run: ["hr", "pace", "power", "speed", "cadence", "rpe"],
  bike: ["hr", "power", "speed", "cadence", "rpe"],
  swim: ["hr", "pace", "rpe"],
} as const satisfies Record<string, readonly string[]>;
export type PlannedWorkout = z.infer<typeof PlannedWorkout>;

export function defaultExecution(sport: z.infer<typeof Sport>, subSport?: string) {
  if (sport === "bike" && subSport === "indoor_bike") return "mywhoosh" as const;
  if (sport === "strength" || sport === "other") return "none" as const;
  return "workoutkit" as const;
}

// ---------------- event (race) ----------------

export const Event = z.object({
  id: z.uuid(),
  name: z.string().min(1).max(120),
  sport: z.enum(["run", "trail", "triathlon", "duathlon", "bike", "brevet", "swim", "other"]),
  status: z.enum(["idea", "planned", "registered", "done", "dnf", "cancelled"]),
  datePrecision: z.enum(["day", "month_part", "month", "season", "year"]),
  dateFrom: IsoDate,
  dateTo: IsoDate,
  dateText: z.string().max(80).optional(),
  startTime: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/).optional(),
  timezone: TimeZone.optional(),
  distanceM: z.number().positive().optional(),
  format: z.string().max(40).optional(),
  priority: z.enum(["A", "B", "C"]).optional(),
  goal: z.string().max(300).optional(),
  url: z.url().optional(),
  notes: z.string().max(20_000).optional(),
  result: z.object({
    timeSec: z.number().positive().optional(),
    place: z.string().max(40).optional(),
    notes: z.string().max(1000).optional(),
  }).optional(),
  /** The race's own activity (finish line recording); the detailed race analysis lives in its coachNotes. */
  activityId: z.uuid().optional(),
  notebookRefs: NotebookRefs,
}).refine((e) => e.dateFrom <= e.dateTo, { message: "dateFrom must be ≤ dateTo" })
  .refine((e) => e.datePrecision !== "day" || e.dateFrom === e.dateTo, {
    message: "datePrecision 'day' needs dateFrom == dateTo",
  });
export type Event = z.infer<typeof Event>;

// ---------------- journal ----------------

export const JournalEntry = z.object({
  id: z.uuid(),
  date: IsoDate,
  text: z.string().min(1).max(4000),
  tags: z.array(z.string().min(1).max(30)).max(10).default([]),
  activityId: z.string().optional(),
  eventId: z.uuid().optional(),
  gearId: z.string().optional(),
  due: IsoDate.optional(),
  closedAt: z.string().optional(),
});
export type JournalEntry = z.infer<typeof JournalEntry>;

// ---------------- notebook ----------------

export const NotebookPage = z.object({
  slug: Slug,
  title: z.string().min(1).max(80),
  content: z.string().max(20_000),
  pinned: z.boolean().default(false),
});
export type NotebookPage = z.infer<typeof NotebookPage>;

/** Total characters of pinned notebook pages included verbatim in get_context. */
export const PINNED_NOTEBOOK_LIMIT = 40_000;
