import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import type { Doc } from "../../db/documents.ts";
import {
  defaultExecution,
  Execution,
  IsoDate,
  PlannedWorkout,
  type Profile,
  Sport,
  Week,
} from "../../domain/entities.ts";
import { estimate, resolveStructure, unresolvedTargets, workoutStatus } from "../../domain/plan.ts";
import { deliveryOf } from "../../domain/delivery.ts";
import type { DeliveryRow, DeviceRow } from "../../db/deliveries.ts";
import type { ActivityRow } from "../../db/activities.ts";
import { brief } from "./activities.ts";
import { addDays, daysBetween, mondayOf } from "../../domain/time.ts";
import type { McpContext } from "../server.ts";
import { defineTool, parseItem, ToolError, Why } from "../util.ts";

const STRUCTURE_HELP = `structure (run/bike/swim): {steps:[Step|Repeat]}.
Step = {type:"step", id, kind: warmup|work|recovery|rest|cooldown|drill, label?, duration, target?, secondary?[], note?}.
duration = {type:"time", sec} | {type:"distance", m} | {type:"open", estimateSec?} — "open" = no fixed length, ends on Lap.
target = {metric: hr|pace|power|speed|cadence|rpe, low?, high?, unit: abs|pct_threshold}. abs units: bpm, pace sec/km (swim sec/100m), W.
The main target is what the watch guides by; put HR corridors on easy steps. Repeat = {type:"repeat", id, count, steps:[Step]}.
structure (strength): {items:[{type:"exercise", id, exercise, sets, reps, weightKg|null, rpe?, holdSec?, perSide?, note?} | {type:"superset", id, rounds, items:[…]}]}.
weightKg null = by feel. Never invent weights: take them from history or leave null + RPE.`;

const PlanItem = z.object({
  date: IsoDate,
  order: z.number().int().min(0).max(20).optional().describe(
    "Position within the day (0 first). Default: after existing workouts of that day.",
  ),
  sport: Sport,
  subSport: z.string().max(30).optional().describe(
    "e.g. indoor_bike, trail, track, treadmill, pool, open_water",
  ),
  title: z.string().min(1).max(80),
  goal: z.string().max(140).optional().describe("The quality this session trains, not logistics."),
  notes: z.string().max(1000).optional().describe("How to execute, fueling, cues."),
  key: z.boolean().optional(),
  tags: z.array(z.string().max(30)).max(10).optional().describe(
    "Context: indoor, heat, race, test, group, commute, openwater …",
  ),
  notebookRefs: z.array(z.string()).max(10).optional(),
  execution: Execution.optional().describe(
    "workoutkit (default for run/bike/swim) | mywhoosh (indoor bike) | none (strength/other)",
  ),
  structure: z.record(z.string(), z.unknown()).optional().describe(STRUCTURE_HELP),
});

function summary(
  doc: Doc<PlannedWorkout>,
  profile: Profile,
  today: string,
  activity: ActivityRow | undefined,
  lastChange?: { at: Date; why: string | null },
  delivery?: { rows: DeliveryRow[]; devices: DeviceRow[] },
  /** Strength: done when sets were logged (app or log_strength_session). */
  lifted = false,
) {
  const w = doc.data;
  const status = workoutStatus(w, Boolean(activity) || lifted, today);
  const est = w.sport === "strength" || !w.structure
    ? null
    : estimate(w.structure, w.sport, profile);
  return {
    id: w.id,
    date: w.date,
    order: w.order,
    sport: w.sport,
    subSport: w.subSport,
    title: w.title,
    goal: w.goal,
    key: w.key,
    tags: w.tags,
    execution: w.execution,
    status,
    skipped: w.skipped ?? undefined,
    delivery: delivery
      ? deliveryOf(w, doc.version, status, today, delivery.rows, delivery.devices)
      : undefined,
    activity: activity
      ? {
        id: activity.id,
        durationSec: activity.durationSec,
        distanceM: activity.distanceM ?? undefined,
      }
      : undefined,
    estimate: est ? { durationSec: est.durationSec, distanceM: est.distanceM } : undefined,
    version: doc.version,
    lastChange: lastChange ? { at: lastChange.at.toISOString(), why: lastChange.why } : undefined,
  };
}

async function nextOrder(ctx: McpContext, userId: string, date: string): Promise<number> {
  const docs = await ctx.docs.listByDate<PlannedWorkout>(userId, "planned_workout", date, date);
  return docs.reduce((m, d) => Math.max(m, d.data.order + 1), 0);
}

export function registerPlanTools(server: McpServer, ctx: McpContext): void {
  defineTool(server, ctx, "get_plan", {
    title: "Get plan",
    description:
      "Weeks (title/header/review) → days → planned workouts (id, order, status, estimate, delivery to the watch, last change with why) for a date range, plus events in range. Max 62 days. Use include_structure only when you need step details.",
    input: {
      from: IsoDate,
      to: IsoDate,
      include_structure: z.boolean().optional(),
    },
    readOnly: true,
  }, async ({ from, to, include_structure }, env) => {
    if (to < from) throw new ToolError("bad_range", "to must be ≥ from");
    if (daysBetween(from, to) > 62) throw new ToolError("bad_range", "range is limited to 62 days");
    const profile = await env.profile();
    const docs = await ctx.docs.listByDate<PlannedWorkout>(env.userId, "planned_workout", from, to);
    const last = await ctx.docs.lastChanges(env.userId, "planned_workout", docs.map((d) => d.id));
    const done = await ctx.activities.byPlanned(env.userId, docs.map((d) => d.id));
    const lifted = await ctx.strength.donePlanned(env.userId, docs.map((d) => d.id));
    const today = (await env.now()).date;
    const delivery = {
      rows: await ctx.deliveries.forWorkouts(env.userId, docs.map((d) => d.id)),
      devices: await ctx.deliveries.devices(env.userId),
    };
    const weekIds: string[] = [];
    for (let m = mondayOf(from); m <= to; m = addDays(m, 7)) weekIds.push(m);
    const weeks = await ctx.docs.getMany<Week>(env.userId, "week", weekIds);
    const days = new Map<string, unknown[]>();
    for (const d of docs) {
      const s = summary(
        d,
        profile,
        today,
        done.get(d.id),
        last.get(d.id),
        delivery,
        lifted.has(d.id),
      );
      const item = include_structure
        ? { ...s, structure: d.data.structure, notes: d.data.notes }
        : s;
      days.set(d.data.date, [...(days.get(d.data.date) ?? []), item]);
    }
    // Everything actually done on each day (matched or not), in start order.
    const done_ = await ctx.activities.list(env.userId, { from, to, limit: 500 });
    const actual = new Map<string, unknown[]>();
    for (const a of [...done_].reverse()) {
      actual.set(a.localDate, [...(actual.get(a.localDate) ?? []), brief(a)]);
    }
    const dates = [...new Set([...days.keys(), ...actual.keys()])].sort();
    return {
      weeks: weeks.map((w) => w.data).sort((a, b) => a.weekStart.localeCompare(b.weekStart)),
      days: dates.map((date) => ({
        date,
        workouts: days.get(date) ?? [],
        activities: actual.get(date) ?? [],
      })),
      howToRead:
        "workouts = plan; activities = what was actually recorded that day (start order; plannedWorkoutId shows the match). status: done (activity matched) / skipped (with reason) / missed (date passed, nothing matched) / planned. A missed workout with a fitting activity that day (no plannedWorkoutId) = link it with link_activities. estimate is partial when steps are open or lack pace targets.",
    };
  });

  defineTool(server, ctx, "get_planned_workout", {
    title: "Get planned workout",
    description:
      "Full planned workout: status, structure, targets resolved to absolute values (what the watch gets; unresolved ones are flagged), estimate, notes, delivery to the watch, change history. Deleted workouts are returned with deleted:true and their history so they can be restored with revert_change. Read this before editing a workout.",
    input: { id: z.uuid() },
    readOnly: true,
  }, async ({ id }, env) => {
    const doc = await ctx.docs.getIncludingDeleted<PlannedWorkout>(
      env.userId,
      "planned_workout",
      id,
    );
    if (!doc) throw new ToolError("not_found", `planned workout ${id} not found`);
    const profile = await env.profile();
    const w = doc.data;
    const activity = (await ctx.activities.byPlanned(env.userId, [id])).get(id);
    const today = (await env.now()).date;
    const lifted = (await ctx.strength.donePlanned(env.userId, [id])).has(id);
    const status = doc.deletedAt ? "deleted" : workoutStatus(w, Boolean(activity) || lifted, today);
    const delivery = deliveryOf(
      w,
      doc.version,
      status,
      today,
      await ctx.deliveries.forWorkouts(env.userId, [id]),
      await ctx.deliveries.devices(env.userId),
    );
    const history = await ctx.docs.changes(env.userId, {
      entity: "planned_workout",
      entityId: id,
      limit: 5,
    });
    return {
      workout: { ...w, version: doc.version },
      status,
      ...(activity ? { activityId: activity.id } : {}),
      ...(doc.deletedAt ? { deleted: true, deletedAt: doc.deletedAt } : {}),
      delivery,
      resolved: w.structure && w.sport !== "strength"
        ? resolveStructure(w.structure, w.sport, profile)
        : undefined,
      estimate: w.structure && w.sport !== "strength"
        ? estimate(w.structure, w.sport, profile)
        : undefined,
      history: history.map((h) => ({
        changeId: h.id,
        at: h.at,
        op: h.op,
        actor: h.actor,
        why: h.why,
      })),
    };
  });

  defineTool(server, ctx, "plan_workouts", {
    title: "Plan workouts",
    description:
      `Create workouts (≤40, atomic: all or nothing). Applies immediately and syncs to the athlete's phone and watch; every change is in get_changes and can be undone with revert_change. Use dryRun to validate first. Structure grammar: see the \`structure\` field.`,
    input: {
      items: z.array(PlanItem).min(1).max(40),
      why: Why,
      dryRun: z.boolean().optional(),
    },
  }, async ({ items, why, dryRun }, env) => {
    const prepared: PlannedWorkout[] = [];
    const orderByDate = new Map<string, number>();
    for (const [index, item] of items.entries()) {
      let order = item.order;
      if (order === undefined) {
        order = orderByDate.get(item.date) ?? await nextOrder(ctx, env.userId, item.date);
        orderByDate.set(item.date, order + 1);
      }
      prepared.push(parseItem(PlannedWorkout, {
        ...item,
        id: crypto.randomUUID(),
        order,
        execution: item.execution ?? defaultExecution(item.sport, item.subSport),
      }, index));
    }
    const profile = await env.profile();
    const warnings = prepared.flatMap((w, item) =>
      w.structure && w.sport !== "strength"
        ? unresolvedTargets(w.structure, w.sport, profile).map((u) => ({ item, ...u }))
        : []
    );
    const warn = warnings.length ? { warnings } : {};
    if (dryRun) return { dryRun: true, valid: prepared.length, ...warn };
    const meta = await env.meta("plan_workouts", why);
    const results = await ctx.docs.transaction(async (tx) => {
      const out = [];
      for (const w of prepared) {
        out.push(await ctx.docs.mutate(tx, env.userId, "planned_workout", w.id, w, meta));
      }
      return out;
    });
    return {
      created: results.map((r, i) => ({
        id: r.id,
        changeId: r.changeId,
        date: prepared[i].date,
        title: prepared[i].title,
      })),
      ...warn,
    };
  });

  defineTool(server, ctx, "update_planned_workout", {
    title: "Update planned workout",
    description:
      "Edit one workout in place (partial patch). Move = change `date`. Skip = `skipped: {reason}`; un-skip = `skipped: null`. Replacing a workout = delete it and plan a new one. Read get_planned_workout first.",
    input: {
      id: z.uuid(),
      patch: PlanItem.partial().extend({
        structure: z.record(z.string(), z.unknown()).optional().describe(
          "Whole new structure; same grammar as plan_workouts.structure.",
        ),
        skipped: z.object({ reason: z.string().min(1).max(200) }).nullable().optional(),
      }),
      why: Why,
    },
  }, async ({ id, patch, why }, env) => {
    const doc = await ctx.docs.get<PlannedWorkout>(env.userId, "planned_workout", id);
    if (!doc) throw new ToolError("not_found", `planned workout ${id} not found`);
    const { skipped, ...rest } = patch;
    const next: Record<string, unknown> = { ...doc.data, ...rest };
    if (skipped === null) delete next.skipped;
    else if (skipped) next.skipped = { reason: skipped.reason, at: ctx.now().toISOString() };
    if (rest.date && rest.date !== doc.data.date && rest.order === undefined) {
      next.order = await nextOrder(ctx, env.userId, rest.date);
    }
    const w = PlannedWorkout.parse(next);
    const unresolved = w.structure && w.sport !== "strength"
      ? unresolvedTargets(w.structure, w.sport, await env.profile())
      : [];
    const meta = await env.meta("update_planned_workout", why);
    const r = await ctx.docs.transaction((tx) =>
      ctx.docs.mutate(tx, env.userId, "planned_workout", id, w, meta)
    );
    return {
      ...(unresolved.length ? { warnings: unresolved } : {}),
      updated: {
        id,
        changeId: r.changeId,
        version: r.version,
        status: w.skipped ? "skipped" : "planned",
      },
    };
  });

  defineTool(server, ctx, "delete_planned_workouts", {
    title: "Delete planned workouts",
    description: "Remove workouts from the plan (soft delete, undo with revert_change).",
    input: { ids: z.array(z.uuid()).min(1).max(40), why: Why },
    destructive: true,
  }, async ({ ids, why }, env) => {
    const meta = await env.meta("delete_planned_workouts", why);
    const results = await ctx.docs.transaction(async (tx) => {
      const out = [];
      for (const id of ids) {
        out.push(await ctx.docs.mutate(tx, env.userId, "planned_workout", id, null, meta));
      }
      return out;
    });
    return { deleted: results.map((r) => ({ id: r.id, changeId: r.changeId })) };
  });

  defineTool(server, ctx, "copy_planned_workouts", {
    title: "Copy planned workouts",
    description:
      "Copy workouts with exact structure/notes/tags: either specific `ids` or everything in `fromDate..toDate`, shifted by `shiftDays` (e.g. 7 = repeat last week). Adds, never replaces. Use for recurring sessions like gym A/B.",
    input: {
      ids: z.array(z.uuid()).max(40).optional(),
      fromDate: IsoDate.optional(),
      toDate: IsoDate.optional(),
      shiftDays: z.number().int().min(-365).max(365),
      why: Why,
    },
  }, async ({ ids, fromDate, toDate, shiftDays, why }, env) => {
    let source: Doc<PlannedWorkout>[];
    if (ids?.length) {
      source = await ctx.docs.getMany<PlannedWorkout>(env.userId, "planned_workout", ids);
    } else if (fromDate && toDate) {
      if (daysBetween(fromDate, toDate) > 31) {
        throw new ToolError("bad_range", "copy range ≤ 31 days");
      }
      source = await ctx.docs.listByDate<PlannedWorkout>(
        env.userId,
        "planned_workout",
        fromDate,
        toDate,
      );
    } else throw new ToolError("bad_request", "give ids or fromDate+toDate");
    if (source.length === 0) throw new ToolError("not_found", "nothing to copy");
    const meta = await env.meta("copy_planned_workouts", why);
    const copies = source.map((d, index) => {
      const { skipped: _skipped, ...rest } = d.data;
      return parseItem(PlannedWorkout, {
        ...rest,
        id: crypto.randomUUID(),
        date: addDays(d.data.date, shiftDays),
      }, index);
    });
    const results = await ctx.docs.transaction(async (tx) => {
      const out = [];
      for (const w of copies) {
        out.push(await ctx.docs.mutate(tx, env.userId, "planned_workout", w.id, w, meta));
      }
      return out;
    });
    return {
      created: results.map((r, i) => ({
        id: r.id,
        changeId: r.changeId,
        date: copies[i].date,
        title: copies[i].title,
      })),
    };
  });

  defineTool(server, ctx, "upsert_week", {
    title: "Write week header/review",
    description:
      "Week-level notes: `title` (one line, e.g. 'БАЗА — неделя 1'), `header` (markdown: vector, what is frozen, rules of the week), `review` (markdown: how the week went). Partial update; weekStart must be a Monday.",
    input: {
      weekStart: IsoDate,
      title: z.string().max(80).optional(),
      header: z.string().max(4000).optional(),
      review: z.string().max(4000).optional(),
      notebookRefs: z.array(z.string()).max(10).optional(),
      why: Why.optional(),
    },
  }, async ({ weekStart, why, ...fields }, env) => {
    const cur = await ctx.docs.get<Week>(env.userId, "week", weekStart);
    const week = Week.parse({ ...(cur?.data ?? {}), ...fields, weekStart });
    const meta = await env.meta("upsert_week", why);
    const r = await ctx.docs.transaction((tx) =>
      ctx.docs.mutate(tx, env.userId, "week", weekStart, week, meta)
    );
    return { week, changeId: r.changeId };
  });
}
