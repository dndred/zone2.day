// Workout structure (docs/03-data-model.md §3–4). Shared by MCP input validation and the app.
import { z } from "zod";

export const Metric = z.enum(["hr", "pace", "power", "speed", "cadence", "rpe"]);

export const Target = z.object({
  metric: Metric,
  low: z.number().nonnegative().optional(),
  high: z.number().nonnegative().optional(),
  /** abs: bpm, sec/km (swim: sec/100m), W, m/s, spm/rpm, RPE 1–10. pct_threshold: % of LTHR/threshold pace/FTP/CSS. */
  unit: z.enum(["abs", "pct_threshold"]).default("abs"),
}).refine((t) => t.low !== undefined || t.high !== undefined, {
  message: "target needs low and/or high",
}).refine((t) => t.low === undefined || t.high === undefined || t.low <= t.high, {
  message: "target.low must be ≤ target.high",
});
export type Target = z.infer<typeof Target>;

export const Duration = z.discriminatedUnion("type", [
  z.object({ type: z.literal("time"), sec: z.number().int().positive().max(86_400) }),
  z.object({ type: z.literal("distance"), m: z.number().positive().max(500_000) }),
  /** Open goal: no fixed length, ends on Lap (or with the workout). estimateSec only feeds estimates. */
  z.object({ type: z.literal("open"), estimateSec: z.number().int().positive().optional() }),
]);

const StepId = z.string().min(1).max(40);

export const Step = z.object({
  type: z.literal("step"),
  id: StepId,
  kind: z.enum(["warmup", "work", "recovery", "rest", "cooldown", "drill"]),
  label: z.string().max(60).optional(),
  duration: Duration,
  target: Target.optional(),
  secondary: z.array(Target).max(3).optional(),
  guard: z.object({
    metric: z.literal("hr"),
    low: z.number().optional(),
    high: z.number().optional(),
  }).optional(),
  cadence: z.object({ low: z.number().optional(), high: z.number().optional() }).optional(),
  swim: z.object({
    stroke: z.enum(["free", "back", "breast", "fly", "im", "choice"]).optional(),
    mode: z.enum(["swim", "kick", "pull", "drill"]).optional(),
    equipment: z.array(z.enum(["paddles", "pullbuoy", "fins", "board", "snorkel"])).max(3)
      .optional(),
  }).optional(),
  note: z.string().max(120).optional(),
});
export type Step = z.infer<typeof Step>;

export const Repeat = z.object({
  type: z.literal("repeat"),
  id: StepId,
  count: z.number().int().min(1).max(50),
  steps: z.array(Step).min(1).max(10),
});
export type Repeat = z.infer<typeof Repeat>;

export const EnduranceStructure = z.object({
  schema: z.literal(1).default(1),
  poolLengthM: z.number().positive().max(100).optional(),
  steps: z.array(z.discriminatedUnion("type", [Step, Repeat])).min(1).max(60),
}).superRefine((s, ctx) => {
  const ids = new Set<string>();
  const visit = (id: string, path: (string | number)[]) => {
    if (ids.has(id)) ctx.addIssue({ code: "custom", message: `duplicate step id '${id}'`, path });
    ids.add(id);
  };
  s.steps.forEach((n, i) => {
    visit(n.id, ["steps", i, "id"]);
    if (n.type === "repeat") {
      n.steps.forEach((st, j) => visit(st.id, ["steps", i, "steps", j, "id"]));
    }
  });
});
export type EnduranceStructure = z.infer<typeof EnduranceStructure>;

const SetSpec = z.object({
  reps: z.number().int().positive().max(100).optional(),
  weightKg: z.number().nonnegative().max(500).nullable().optional(),
  holdSec: z.number().int().positive().max(3600).optional(),
  distanceM: z.number().positive().max(10_000).optional(),
  rpe: z.number().min(1).max(10).optional(),
});

const ExerciseFields = {
  exercise: z.string().min(1).max(80),
  reps: z.number().int().positive().max(100).optional(),
  /** null = «по ощущениям» (not assigned). */
  weightKg: z.number().nonnegative().max(500).nullable().optional(),
  rpe: z.number().min(1).max(10).optional(),
  holdSec: z.number().int().positive().max(3600).optional(),
  distanceM: z.number().positive().max(10_000).optional(),
  perSide: z.boolean().optional(),
  note: z.string().max(200).optional(),
};

export const Exercise = z.object({
  type: z.literal("exercise"),
  id: StepId,
  sets: z.number().int().min(1).max(20).optional(),
  setList: z.array(SetSpec).min(1).max(20).optional(),
  ...ExerciseFields,
}).refine((e) => e.sets !== undefined || e.setList !== undefined, {
  message: "exercise needs sets or setList",
});

export const Superset = z.object({
  type: z.literal("superset"),
  id: StepId,
  rounds: z.number().int().min(1).max(20),
  items: z.array(z.object(ExerciseFields)).min(1).max(8),
});

export const StrengthStructure = z.object({
  schema: z.literal(1).default(1),
  items: z.array(z.discriminatedUnion("type", [Exercise, Superset])).min(1).max(40),
});
export type StrengthStructure = z.infer<typeof StrengthStructure>;

/** Flattens repeats into the executed sequence (repeat × steps). */
export function flattenSteps(structure: EnduranceStructure): Step[] {
  const out: Step[] = [];
  for (const node of structure.steps) {
    if (node.type === "step") out.push(node);
    else for (let i = 0; i < node.count; i++) out.push(...node.steps);
  }
  return out;
}
