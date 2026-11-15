import type { McpServer } from "@modelcontextprotocol/server";
import { z } from "zod";
import type { PlannedWorkout } from "../../domain/entities.ts";
import { IsoDate } from "../../domain/entities.ts";
import { deliveryOf } from "../../domain/delivery.ts";
import { workoutStatus } from "../../domain/plan.ts";
import { addDays } from "../../domain/time.ts";
import type { McpContext } from "../server.ts";
import { defineTool, ToolError } from "../util.ts";

export function registerDeliveryTools(server: McpServer, ctx: McpContext): void {
  defineTool(server, ctx, "get_delivery_status", {
    title: "Get delivery status",
    description:
      "Reference tool: are planned workouts on the athlete's Apple Watch, and when did their phone last sync. Delivery is automatic (the app schedules today…+7 days after every sync), so call this only when the athlete asks or something looks wrong — not after each plan change. States: on_watch (current version), outdated (an older version is on the watch; the phone has not synced the change yet), not_on_watch. Default range: today … +7 days.",
    input: {
      ids: z.array(z.uuid()).max(40).optional(),
      from: IsoDate.optional(),
      to: IsoDate.optional(),
    },
    readOnly: true,
  }, async ({ ids, from, to }, env) => {
    const today = (await env.now()).date;
    const start = from ?? today;
    const end = to ?? addDays(start, 7);
    if (end < start) throw new ToolError("bad_range", "to must be ≥ from");
    const docs = ids
      ? await ctx.docs.getMany<PlannedWorkout>(env.userId, "planned_workout", ids)
      : await ctx.docs.listByDate<PlannedWorkout>(env.userId, "planned_workout", start, end);
    const rows = await ctx.deliveries.forWorkouts(env.userId, docs.map((d) => d.id));
    const devices = await ctx.deliveries.devices(env.userId);
    const done = await ctx.activities.byPlanned(env.userId, docs.map((d) => d.id));
    const lifted = await ctx.strength.donePlanned(env.userId, docs.map((d) => d.id));
    return {
      workouts: docs.map((d) => {
        const status = workoutStatus(d.data, done.has(d.id) || lifted.has(d.id), today);
        return {
          id: d.id,
          date: d.data.date,
          title: d.data.title,
          execution: d.data.execution,
          version: d.version,
          status,
          delivery: deliveryOf(d.data, d.version, status, today, rows, devices) ??
            { state: "not_applicable" },
        };
      }),
      devices: devices.map((dv) => ({
        name: dv.name ?? dv.id,
        model: dv.model ?? undefined,
        appVersion: dv.appVersion ?? undefined,
        lastSeenAt: dv.lastSeenAt.toISOString(),
        lastPullAt: dv.lastPullAt?.toISOString(),
        watchError: dv.watchError ?? undefined,
      })),
      howToRead: [
        "not_applicable = not a watch workout (mywhoosh/none), already done/skipped, or in the past.",
        "If the phone has not synced for long, the athlete needs to open the app once (no push yet); do not nag about it otherwise.",
      ],
    };
  });
}
