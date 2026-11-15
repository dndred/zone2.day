// Adding activities by hand through MCP: a FIT file (upload link or base64) or a manual entry.
import type { McpServer } from "@modelcontextprotocol/server";
import { z } from "zod";
import { randomToken, sha256 } from "../../auth/crypto.ts";
import type { ActivityRow } from "../../db/activities.ts";
import { type PlannedWorkout, Sport } from "../../domain/entities.ts";
import { InvalidFitError } from "../../domain/fit.ts";
import { manualSummary } from "../../domain/manual.ts";
import { effectiveTimezone, isValidDate, localParts, zonedToUtc } from "../../domain/time.ts";
import { ingestFit } from "../../ingest/fit.ts";
import { matchPlan } from "../../ingest/healthkit.ts";
import type { McpContext } from "../server.ts";
import { defineTool, type ToolEnv, ToolError, Why } from "../util.ts";
import { brief } from "./activities.ts";

const UPLOAD_TTL_SEC = 60 * 60;

/** The planned workout exists and no other activity holds it. */
async function checkPlanned(ctx: McpContext, userId: string, plannedId: string) {
  const doc = await ctx.docs.get<PlannedWorkout>(userId, "planned_workout", plannedId);
  if (!doc) throw new ToolError("not_found", `planned workout ${plannedId} not found`);
  return doc.data;
}

function planWarnings(a: ActivityRow, w: PlannedWorkout | null): string[] {
  if (!w) return [];
  const out: string[] = [];
  if (w.sport !== a.sport) out.push(`sport ${a.sport} ≠ planned ${w.sport} (${w.title})`);
  if (w.date !== a.localDate) out.push(`done ${a.localDate}, planned ${w.date} (${w.title})`);
  return out;
}

const Annotations = {
  title: z.string().min(1).max(80).optional().describe("In the athlete's language"),
  athleteNotes: z.string().max(4000).optional().describe(
    "The athlete's own words about this session (not yours; your analysis → update_activity coachNotes)",
  ),
  rpe: z.number().int().min(1).max(10).optional(),
  tags: z.array(z.string().max(30)).max(10).optional(),
  plannedWorkoutId: z.uuid().optional().describe(
    "Planned workout this fulfils. Omit to match automatically (same date and sport).",
  ),
};

async function finish(
  ctx: McpContext,
  env: ToolEnv,
  tool: string,
  why: string | undefined,
  activityId: string,
  a: { title?: string; athleteNotes?: string; rpe?: number; tags?: string[] },
  planned: PlannedWorkout | null,
  extra: Record<string, unknown>,
) {
  if (a.title || a.athleteNotes || a.rpe || a.tags) {
    await ctx.activities.annotate(env.userId, activityId, a);
  }
  const row = (await ctx.activities.get(env.userId, activityId))!;
  const meta = await env.meta(tool, why);
  const changeId = await ctx.docs.logExternal(
    env.userId,
    meta,
    "activity",
    row.id,
    extra.created === false ? "update" : "create",
    null,
    {
      source: row.source,
      date: row.localDate,
      sport: row.sport,
      plannedWorkoutId: row.plannedWorkoutId,
    },
  );
  const plan = planned ??
    (row.plannedWorkoutId
      ? (await ctx.docs.get<PlannedWorkout>(env.userId, "planned_workout", row.plannedWorkoutId))
        ?.data ?? null
      : null);
  return {
    activity: brief(row),
    ...extra,
    plan: plan ? { id: plan.id, title: plan.title, date: plan.date } : null,
    warnings: [...planWarnings(row, plan), ...((extra.warnings as string[]) ?? [])],
    changeId,
  };
}

export function registerActivityInputTools(server: McpServer, ctx: McpContext): void {
  defineTool(server, ctx, "create_upload_link", {
    title: "Create upload link",
    description:
      "One-time link (valid 1 h) where the athlete picks a .fit file in the browser — the way to get a file from a chat client, which cannot pass binary files to tools. Give the athlete the url; when they say it is uploaded, call import_activity_file({uploadId}).",
    input: {},
  }, async (_args, env) => {
    const token = randomToken("z2u", 24);
    const expiresAt = new Date(ctx.now().getTime() + UPLOAD_TTL_SEC * 1000);
    const up = await ctx.uploads.create(env.userId, await sha256(token), "fit", expiresAt);
    return {
      uploadId: up.id,
      url: `${ctx.config.publicBaseUrl}/u/${token}`,
      expiresAt: expiresAt.toISOString(),
      accepts: "one .fit activity file, ≤25 MB",
    };
  });

  defineTool(server, ctx, "import_activity_file", {
    title: "Import activity file",
    description:
      "Create an activity from a FIT file — e.g. a MyWhoosh ride export with power, cadence and HR inside, or any watch/bike computer file. The file always comes through create_upload_link: pass its uploadId once the athlete says it is uploaded. Summary, laps and streams are computed like for Apple Health workouts; the original FIT is kept byte for byte. Re-importing the same file returns the same activity. A copy of the same session from a worse source (e.g. Strava's copy in Apple Health) is marked as its duplicate, and the plan link moves to the FIT. Matched to the plan automatically unless plannedWorkoutId is given. Writes immediately; logged in get_changes.",
    input: {
      uploadId: z.uuid().describe("From create_upload_link"),
      ...Annotations,
      why: Why.optional(),
    },
  }, async ({ uploadId, why, plannedWorkoutId, ...ann }, env) => {
    const up = await ctx.uploads.get(env.userId, uploadId);
    if (!up) throw new ToolError("not_found", `upload ${uploadId} not found`);
    if (!up.uploadedAt || !up.storageKey) {
      const expired = up.expiresAt <= ctx.now();
      throw new ToolError(
        expired ? "expired" : "not_uploaded",
        expired ? "the upload link expired before a file was uploaded" : "no file uploaded yet",
        expired
          ? "Create a new link with create_upload_link"
          : "Ask the athlete to open the link and upload the file, then call again",
      );
    }
    const raw = await ctx.blobs.get(up.storageKey);
    if (!raw) throw new ToolError("not_found", "uploaded file is missing in storage");
    const bytes = raw;

    const planned = plannedWorkoutId ? await checkPlanned(ctx, env.userId, plannedWorkoutId) : null;
    let result;
    try {
      result = await ingestFit(ctx, env.userId, bytes, {
        now: ctx.now(),
        plannedWorkoutId: planned?.id,
      });
    } catch (err) {
      if (err instanceof InvalidFitError) {
        throw new ToolError(
          "invalid_file",
          err.message,
          "Expected a .fit activity export (not .zwo/.gpx/.tcx)",
        );
      }
      throw err;
    }
    await ctx.uploads.markImported(env.userId, uploadId, result.activityId);

    const row = (await ctx.activities.get(env.userId, result.activityId))!;
    const replaced = (await ctx.activities.overlapping(
      env.userId,
      row.sport,
      row.startAt,
      row.endAt,
      row.id,
    )).filter((o) => o.duplicateOf === row.id).map((o) => ({
      id: o.id,
      source: o.sourceApp ?? o.source,
    }));
    return await finish(ctx, env, "import_activity_file", why, row.id, ann, planned, {
      created: result.created,
      duplicateOf: result.duplicateOf ?? undefined,
      replacedDuplicates: replaced.length ? replaced : undefined,
      warnings: result.duplicateOf
        ? [
          `this file duplicates activity ${result.duplicateOf} from a better source; it is hidden from lists`,
        ]
        : [],
    });
  });

  defineTool(server, ctx, "create_activity", {
    title: "Create activity by hand",
    description:
      "Record a workout that has no file: from the athlete's words, a paper log, a gym/treadmill display, a race result. Only totals (no laps, streams or zones) — prefer import_activity_file when a FIT exists. Never invent numbers: leave unknown fields out. start = local wall clock 'YYYY-MM-DDTHH:MM' in the athlete's zone that day (or ISO with offset). Matched to the plan automatically (same date and sport) unless plannedWorkoutId is given. A same-sport activity overlapping in time comes back as a warning (it may already be recorded). Writes immediately; logged in get_changes.",
    input: {
      sport: Sport,
      subSport: z.string().max(30).optional().describe(
        "e.g. indoor_bike, treadmill, trail, track, pool, open_water, walk, hike",
      ),
      start: z.string().describe("'2026-11-15T08:30' (athlete local) or ISO with offset"),
      durationSec: z.number().int().min(60).max(48 * 3600).describe("Elapsed time"),
      movingSec: z.number().int().min(1).max(48 * 3600).optional(),
      distanceM: z.number().positive().max(1_000_000).optional(),
      hrAvg: z.number().int().min(30).max(240).optional(),
      hrMax: z.number().int().min(30).max(240).optional(),
      powerAvg: z.number().min(1).max(2000).optional().describe("W"),
      elevationGainM: z.number().min(0).max(20_000).optional(),
      energyKcal: z.number().min(0).max(20_000).optional(),
      ...Annotations,
      why: Why,
    },
  }, async (args, env) => {
    const { start, sport, subSport, why, plannedWorkoutId, title, athleteNotes, rpe, tags } = args;
    if (args.movingSec !== undefined && args.movingSec > args.durationSec) {
      throw new ToolError("bad_input", "movingSec must be ≤ durationSec");
    }
    if (args.hrAvg && args.hrMax && args.hrAvg > args.hrMax) {
      throw new ToolError("bad_input", "hrAvg must be ≤ hrMax", "Swap them");
    }
    const profile = await env.profile();
    let startAt: Date;
    let tz: string;
    if (/[zZ]$|[+-]\d{2}:?\d{2}$/.test(start)) {
      startAt = new Date(start);
      if (Number.isNaN(startAt.getTime())) throw new ToolError("bad_input", `bad start ${start}`);
      tz = effectiveTimezone(profile, localParts(startAt, profile.timezone).date);
    } else {
      const date = start.slice(0, 10);
      if (!isValidDate(date)) throw new ToolError("bad_input", `bad start ${start}`);
      tz = effectiveTimezone(profile, date);
      try {
        startAt = zonedToUtc(start, tz);
      } catch (err) {
        throw new ToolError("bad_input", (err as Error).message);
      }
    }
    if (startAt.getTime() > ctx.now().getTime()) {
      throw new ToolError(
        "bad_input",
        "start is in the future",
        "Plan it with plan_workouts instead",
      );
    }
    const endAt = new Date(startAt.getTime() + args.durationSec * 1000);
    const local = localParts(startAt, tz);
    const planned = plannedWorkoutId ? await checkPlanned(ctx, env.userId, plannedWorkoutId) : null;

    const summary = manualSummary({
      sport,
      subSport: subSport ?? null,
      startLocal: local.time,
      timezone: tz,
      elapsedSec: args.durationSec,
      movingSec: args.movingSec,
      distanceM: args.distanceM,
      hrAvg: args.hrAvg,
      hrMax: args.hrMax,
      powerAvg: args.powerAvg,
      elevationGainM: args.elevationGainM,
      energyKcal: args.energyKcal,
    });
    const overlap = await ctx.activities.overlapping(
      env.userId,
      sport,
      startAt,
      endAt,
      crypto.randomUUID(),
    );
    const { row } = await ctx.activities.upsert(env.userId, {
      source: "manual",
      sourceId: crypto.randomUUID(),
      sourceApp: null,
      sport,
      subSport: subSport ?? null,
      activityType: null,
      startAt,
      endAt,
      timezone: tz,
      localDate: local.date,
      durationSec: args.durationSec,
      distanceM: args.distanceM ?? null,
      summary,
      laps: [],
    });
    if (planned) await ctx.activities.setPlanned(env.userId, row.id, planned.id);
    else await matchPlan(ctx, env.userId, row, local.date);
    return await finish(
      ctx,
      env,
      "create_activity",
      why,
      row.id,
      {
        title,
        athleteNotes,
        rpe,
        tags,
      },
      planned,
      {
        created: true,
        warnings: overlap.filter((o) => !o.duplicateOf).map((o) =>
          `overlaps activity ${o.id} (${
            o.sourceApp ?? o.source
          }, ${o.localDate}) — maybe already recorded; check with the athlete`
        ),
      },
    );
  });
}
