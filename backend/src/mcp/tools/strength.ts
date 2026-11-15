import type { McpServer } from "@modelcontextprotocol/server";
import { z } from "zod";
import { ForeignIdError, type SetInput, type StrengthSession } from "../../db/strength.ts";
import { IsoDate, type PlannedWorkout } from "../../domain/entities.ts";
import { exerciseHistory, logView } from "../../domain/strength.ts";
import type { McpContext } from "../server.ts";
import { defineTool, ToolError, Why } from "../util.ts";

const SetSpec = z.object({
  exercise: z.string().min(1).max(80),
  reps: z.number().int().positive().max(100).optional(),
  weightKg: z.number().nonnegative().max(500).optional().describe("Omit for bodyweight"),
  holdSec: z.number().int().positive().max(3600).optional(),
  distanceM: z.number().positive().max(10_000).optional(),
  rpe: z.number().min(1).max(10).optional(),
  note: z.string().max(200).optional(),
});

const load = (s: { reps?: number; weightKg?: number; holdSec?: number; distanceM?: number }) => ({
  ...(s.reps !== undefined ? { reps: s.reps } : {}),
  ...(s.weightKg !== undefined ? { weightKg: s.weightKg } : {}),
  ...(s.holdSec !== undefined ? { holdSec: s.holdSec } : {}),
  ...(s.distanceM !== undefined ? { distanceM: s.distanceM } : {}),
});

/**
 * Log views with links to deleted planned workouts dropped (the link stays in the DB, so
 * reverting the deletion brings it back).
 */
async function views(ctx: McpContext, userId: string, sessions: StrengthSession[]) {
  const ids = [...new Set(sessions.flatMap((s) => s.plannedWorkoutId ? [s.plannedWorkoutId] : []))];
  const live = new Set(
    (await ctx.docs.getMany(userId, "planned_workout", ids)).map((d) => d.id),
  );
  return sessions.map((s) =>
    logView(
      s.plannedWorkoutId && !live.has(s.plannedWorkoutId) ? { ...s, plannedWorkoutId: null } : s,
    )
  );
}

export function registerStrengthTools(server: McpServer, ctx: McpContext): void {
  defineTool(server, ctx, "get_strength_log", {
    title: "Get strength log",
    description:
      'Gym sessions set by set: plan vs actual ("60×8" = 60 kg × 8 reps, "×12" = bodyweight, "—" = planned but not done), RPE, notes. Logged by the athlete in the app (source app) or by you (source ai). Newest first.',
    input: {
      from: IsoDate.optional(),
      to: IsoDate.optional(),
      exercise: z.string().max(80).optional(),
      limit: z.number().int().min(1).max(60).optional(),
    },
    readOnly: true,
  }, async (args, env) => {
    const sessions = await ctx.strength.list(env.userId, args);
    return { sessions: await views(ctx, env.userId, sessions) };
  });

  defineTool(server, ctx, "get_exercise_history", {
    title: "Get exercise history",
    description:
      "Progression of one exercise: per session the sets done, best set, estimated 1RM (Epley, 1–12 reps), RPE, plan vs actual, and gaps between sessions. The only source for weights in new strength plans — read it before planning a lift.",
    input: {
      exercise: z.string().min(1).max(80),
      sessions: z.number().int().min(2).max(20).optional(),
    },
    readOnly: true,
  }, async ({ exercise, sessions }, env) => {
    const list = await ctx.strength.list(env.userId, { exercise, limit: sessions ?? 8 });
    const names = await ctx.strength.names(env.userId, exercise);
    const history = exerciseHistory(list, names);
    return {
      exercise: names[0],
      aliases: names.length > 1 ? names.slice(1) : undefined,
      ...history,
      howToRead: history.sessions.length
        ? undefined
        : "No sessions with this exercise (check spelling, or merge_exercises if it was logged under another name).",
    };
  });

  defineTool(server, ctx, "log_strength_session", {
    title: "Log strength session",
    description:
      "Record a gym session after the fact (date today or earlier, athlete's time zone): weights moved over from notes, or what the athlete told you in chat. Each set is one item (repeat an exercise for several sets, in order). Link plannedWorkoutId (a strength workout from get_plan) to mark that planned workout done. Undo with revert_change.",
    input: {
      date: IsoDate,
      plannedWorkoutId: z.uuid().optional(),
      sets: z.array(SetSpec).min(1).max(120),
      notes: z.string().max(1000).optional(),
      why: Why,
    },
  }, async ({ date, plannedWorkoutId, sets, notes, why }, env) => {
    const today = (await env.now()).date;
    if (date > today) {
      throw new ToolError(
        "bad_input",
        `date ${date} is in the future (today is ${today})`,
        "Log a session after it happened; plan future gym sessions with plan_workouts",
      );
    }
    const warnings: string[] = [];
    if (plannedWorkoutId) {
      const plan = await ctx.docs.get<PlannedWorkout>(env.userId, "planned_workout", plannedWorkoutId);
      if (!plan) throw new ToolError("not_found", `planned workout ${plannedWorkoutId} not found`);
      if (plan.data.sport !== "strength") {
        throw new ToolError(
          "bad_input",
          `planned workout ${plannedWorkoutId} is ${plan.data.sport}, not strength`,
          "Endurance workouts are fulfilled by activities (link_activities)",
        );
      }
      if (plan.data.date !== date) {
        warnings.push(`done ${date}, planned ${plan.data.date} (${plan.data.title})`);
      }
    }
    const order = new Map<string, number>();
    const count = new Map<string, number>();
    const inputs: SetInput[] = sets.map((s) => {
      const key = s.exercise.trim().toLowerCase();
      if (!order.has(key)) order.set(key, order.size);
      const idx = count.get(key) ?? 0;
      count.set(key, idx + 1);
      return {
        id: crypto.randomUUID(),
        exercise: s.exercise,
        order: order.get(key)!,
        setIndex: idx,
        actual: load(s),
        rpe: s.rpe ?? null,
        note: s.note ?? null,
      };
    });
    const id = crypto.randomUUID();
    const session = await ctx.strength.upsert(
      env.userId,
      { id, date, plannedWorkoutId: plannedWorkoutId ?? null, notes: notes ?? null, sets: inputs },
      "ai",
      ctx.now(),
    );
    const changeId = await ctx.docs.logExternal(
      env.userId,
      await env.meta("log_strength_session", why),
      "strength_session",
      id,
      "create",
      null,
      logView(session),
    );
    return {
      changeId,
      session: logView(session),
      ...(warnings.length ? { warnings } : {}),
    };
  });

  defineTool(server, ctx, "update_strength_log", {
    title: "Update strength log",
    description:
      "Fix logged sets (the athlete said they mistyped a weight, did fewer reps, skipped a set). Set ids come from get_strength_log. Only given fields change; delete:true removes a set; done:false marks it not done.",
    input: {
      sessionId: z.uuid(),
      sets: z.array(z.object({
        id: z.uuid(),
        reps: z.number().int().positive().max(100).optional(),
        weightKg: z.number().nonnegative().max(500).optional(),
        holdSec: z.number().int().positive().max(3600).optional(),
        rpe: z.number().min(1).max(10).optional(),
        note: z.string().max(200).optional(),
        done: z.boolean().optional(),
        delete: z.boolean().optional(),
      })).min(1).max(60),
      notes: z.string().max(1000).optional(),
      why: Why,
    },
  }, async ({ sessionId, sets, notes, why }, env) => {
    const [before] = await ctx.strength.getMany(env.userId, [sessionId]);
    if (!before) throw new ToolError("not_found", `strength session ${sessionId} not found`);
    const patched: SetInput[] = [];
    for (const p of sets) {
      const cur = before.sets.find((x) => x.id === p.id);
      if (!cur) throw new ToolError("not_found", `set ${p.id} is not in session ${sessionId}`);
      const actual = p.done === false ? null : { ...(cur.actual ?? cur.planned ?? {}), ...load(p) };
      patched.push({
        id: cur.id,
        exercise: cur.exercise,
        order: cur.order,
        setIndex: cur.setIndex,
        planned: cur.planned,
        actual,
        rpe: p.rpe ?? cur.rpe,
        note: p.note ?? cur.note,
        loggedAt: cur.loggedAt,
        deleted: p.delete ?? false,
      });
    }
    try {
      const after = await ctx.strength.upsert(
        env.userId,
        {
          id: sessionId,
          date: before.date,
          plannedWorkoutId: before.plannedWorkoutId,
          notes: notes ?? null,
          sets: patched,
        },
        "ai",
        ctx.now(),
      );
      const changeId = await ctx.docs.logExternal(
        env.userId,
        await env.meta("update_strength_log", why),
        "strength_session",
        sessionId,
        "update",
        logView(before),
        logView(after),
      );
      return { changeId, session: (await views(ctx, env.userId, [after]))[0] };
    } catch (err) {
      if (err instanceof ForeignIdError) throw new ToolError("not_found", err.message);
      throw err;
    }
  });

  defineTool(server, ctx, "merge_exercises", {
    title: "Merge exercises",
    description:
      'One movement logged under several names ("Присед", "Приседания со штангой"): move all their sets to `into` and keep the old names as aliases, so history and plans find it under any name.',
    input: {
      names: z.array(z.string().min(1).max(80)).min(1).max(10),
      into: z.string().min(1).max(80),
      why: Why,
    },
  }, async ({ names, into, why }, env) => {
    const result = await ctx.strength.merge(env.userId, names, into);
    const changeId = await ctx.docs.logExternal(
      env.userId,
      await env.meta("merge_exercises", why),
      "exercise",
      result.into,
      "update",
      { names },
      result,
    );
    return { changeId, ...result };
  });
}
