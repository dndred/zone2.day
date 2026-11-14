import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import type { ActivityRow } from "../../db/activities.ts";
import type { PlannedWorkout } from "../../domain/entities.ts";
import { IsoDate } from "../../domain/entities.ts";
import { HealthKitDump, streams } from "../../domain/healthkit.ts";
import { gunzip } from "../../ingest/healthkit.ts";
import type { McpContext } from "../server.ts";
import { defineTool, ToolError } from "../util.ts";

function brief(a: ActivityRow) {
  const s = a.summary as Record<string, unknown>;
  return {
    id: a.id,
    date: a.localDate,
    start: a.startAt,
    sport: a.sport,
    subSport: a.subSport ?? undefined,
    title: a.title ?? undefined,
    durationSec: a.durationSec,
    movingSec: s.movingSec,
    distanceM: a.distanceM ?? undefined,
    paceSecPerKm: s.paceSecPerKm ?? undefined,
    paceSecPer100m: s.paceSecPer100m ?? undefined,
    speedKmh: s.speedKmh ?? undefined,
    hr: s.hr ?? undefined,
    elevationGainM: s.elevationGainM ?? undefined,
    plannedWorkoutId: a.plannedWorkoutId ?? undefined,
    duplicateOf: a.duplicateOf ?? undefined,
    source: `${a.source}:${a.sourceApp ?? ""}`,
  };
}

export function registerActivityTools(server: McpServer, ctx: McpContext): void {
  defineTool(server, ctx, "list_activities", {
    title: "List activities",
    description:
      "Completed workouts imported from Apple Health (and later intervals.icu): date, sport, duration, distance, pace/speed, HR, elevation, link to the planned workout. Newest first; `limit` counts rows (default 30), it is not a date window. Copies of the same session from a worse source (e.g. Strava's copy) are hidden unless includeDuplicates.",
    input: {
      from: IsoDate.optional(),
      to: IsoDate.optional(),
      sport: z.enum(["run", "bike", "swim", "strength", "other"]).optional(),
      limit: z.number().int().min(1).max(100).optional(),
      includeDuplicates: z.boolean().optional(),
    },
    readOnly: true,
  }, async (args, env) => {
    const rows = await ctx.activities.list(env.userId, args);
    return { activities: rows.map(brief) };
  });

  defineTool(server, ctx, "get_activity", {
    title: "Get activity",
    description:
      "Full summary of one activity: moving/elapsed time, distance, pace, HR, running dynamics (power, stride, vertical oscillation, ground contact), cycling power/cadence, swim pool length/strokes, weather (°C), laps/segments with distance and HR, the matched planned workout, files. For curves use get_activity_streams.",
    input: { id: z.uuid() },
    readOnly: true,
  }, async ({ id }, env) => {
    const a = await ctx.activities.get(env.userId, id, { includeDeleted: true });
    if (!a) throw new ToolError("not_found", `activity ${id} not found`);
    const planned = a.plannedWorkoutId
      ? await ctx.docs.get<PlannedWorkout>(env.userId, "planned_workout", a.plannedWorkoutId)
      : null;
    return {
      activity: {
        ...brief(a),
        summary: a.summary,
        laps: a.laps,
        athleteNotes: a.athleteNotes ?? undefined,
        coachNotes: a.coachNotes ?? undefined,
        rpe: a.rpe ?? undefined,
        official: a.official ?? undefined,
        grade: a.grade ?? undefined,
        tags: a.tags,
        timezone: a.timezone,
        ...(a.deletedAt ? { deleted: true } : {}),
      },
      plan: planned
        ? {
          id: planned.data.id,
          title: planned.data.title,
          goal: planned.data.goal,
          structure: planned.data.structure,
        }
        : null,
      files: (await ctx.activities.files(a.id)).map((f) => ({ kind: f.kind, bytes: f.bytes })),
      howToRead: [
        "movingSec excludes pauses; pace uses moving time.",
        "hr.avg is the mean of HR samples (watch records every ~5 s).",
        "Laps are workout segments/laps recorded by the watch (custom workout steps appear as segments).",
        "Interval-by-interval comparison with the plan is not computed yet.",
      ],
    };
  });

  defineTool(server, ctx, "get_activity_streams", {
    title: "Get activity streams",
    description:
      "Curves of one activity resampled into time buckets (default ~200 points; zoom with fromSec/toSec). Channels: heartRate, runningSpeed, runningPower, runningStrideLength, runningVerticalOscillation, runningGroundContactTime, cyclingPower, cyclingCadence, cyclingSpeed, distance (cumulative m), altitude, lat, lon. Columns share the `t` axis (seconds from start).",
    input: {
      id: z.uuid(),
      channels: z.array(z.string()).min(1).max(8).default(["heartRate", "distance"]),
      fromSec: z.number().min(0).optional(),
      toSec: z.number().positive().optional(),
      maxPoints: z.number().int().min(10).max(600).optional(),
    },
    readOnly: true,
  }, async ({ id, channels, fromSec, toSec, maxPoints }, env) => {
    const a = await ctx.activities.get(env.userId, id);
    if (!a) throw new ToolError("not_found", `activity ${id} not found`);
    const file = (await ctx.activities.files(a.id)).find((f) => f.kind === "healthkit_dump");
    if (!file) throw new ToolError("no_streams", "this activity has no raw data");
    const raw = await ctx.blobs.get(file.key);
    if (!raw) throw new ToolError("no_streams", "raw file is missing in storage");
    const dump = HealthKitDump.parse(JSON.parse(new TextDecoder().decode(await gunzip(raw))));
    const from = fromSec ?? 0;
    const to = Math.min(toSec ?? dump.workout.durationSec, dump.workout.durationSec);
    if (to <= from) throw new ToolError("bad_range", "toSec must be > fromSec");
    const points = maxPoints ?? 200;
    const buckets = Math.max(1, Math.min(points, Math.ceil(to - from)));
    const data = streams(dump, channels, from, to, buckets);
    const available = [
      ...Object.keys(dump.samples),
      ...(dump.route.length ? ["lat", "lon", "altitude"] : []),
      "distance",
    ];
    return {
      activityId: id,
      bucketSec: Math.round((to - from) / buckets * 10) / 10,
      columns: data,
      missing: channels.filter((ch) => !(ch in data)),
      available,
    };
  });
}
