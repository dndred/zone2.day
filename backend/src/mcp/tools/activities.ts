import type { McpServer } from "@modelcontextprotocol/server";
import { z } from "zod";
import {
  type ActivityAnnotations,
  type ActivityRow,
  ANNOTATION_KEYS,
} from "../../db/activities.ts";
import type { PlannedWorkout } from "../../domain/entities.ts";
import { IsoDate } from "../../domain/entities.ts";
import { defaultTitle, streams, type Summary } from "../../domain/healthkit.ts";
import { loadDump, NoStreamsError } from "../../sync/streams.ts";
import { resolveStructure } from "../../domain/plan.ts";
import { analysisOf } from "../../domain/analysis.ts";
import { analysisView, ZoneContext } from "./analytics.ts";
import type { McpContext } from "../server.ts";
import { defineTool, ToolError, Why } from "../util.ts";

const COACH_NOTES_MAX = 12_000;
const ATHLETE_NOTES_MAX = 4000;

export function brief(a: ActivityRow) {
  const s = a.summary as Record<string, unknown>;
  const hr = s.hr as { avg?: number; max?: number } | null;
  return {
    id: a.id,
    date: a.localDate,
    startLocal: s.startLocal ?? undefined,
    sport: a.sport,
    subSport: a.subSport ?? undefined,
    kind: s.kind ?? "training",
    title: a.title ?? (s.name ? defaultTitle(s as Summary) : undefined),
    elapsedSec: a.durationSec,
    movingSec: s.movingSec,
    distanceM: a.distanceM ?? undefined,
    distanceKind: s.distanceKind ?? undefined,
    paceSecPerKm: s.paceSecPerKm ?? undefined,
    gapSecPerKm: analysisOf(s)?.gapSecPerKm ?? undefined,
    paceSecPer100m: s.paceSecPer100m ?? undefined,
    speedKmh: s.speedKmh ?? undefined,
    hrAvg: hr?.avg,
    hrMax: hr?.max,
    elevationGainM: s.elevationGainM ?? undefined,
    detail: s.detail ?? undefined,
    intervals: (s.intervals as Record<string, number | null>[] | null)?.map((i) => ({
      startSec: i.startSec,
      durationSec: i.durationSec,
      distanceM: i.distanceM,
      paceSecPerKm: i.paceSecPerKm ?? undefined,
      speedKmh: i.speedKmh ?? undefined,
      hrAvg: i.avgHr ?? undefined,
      hrMax: i.maxHr ?? undefined,
    })),
    plannedWorkoutId: a.plannedWorkoutId ?? undefined,
    duplicateOf: a.duplicateOf ?? undefined,
    source: a.sourceApp ?? a.source,
    device: s.device ?? undefined,
  };
}

export function registerActivityTools(server: McpServer, ctx: McpContext): void {
  defineTool(server, ctx, "list_activities", {
    title: "List activities",
    description:
      "Completed workouts imported from Apple Health (and later intervals.icu): date, sport, duration, distance, pace/speed, HR, elevation, the athlete's manual intervals (e.g. the race part of a session with warm-up), link to the planned workout. Newest first; `limit` counts rows (default 30), it is not a date window. Copies of the same session from a worse source (e.g. Strava's copy) are hidden unless includeDuplicates.",
    input: {
      from: IsoDate.optional(),
      to: IsoDate.optional(),
      sport: z.enum(["run", "bike", "swim", "strength", "other"]).optional(),
      limit: z.number().int().min(1).max(100).optional(),
      includeDuplicates: z.boolean().optional(),
      includeRecovery: z.boolean().optional().describe(
        "Also list non-training sessions (mind & body, yoga, flexibility, cooldown)",
      ),
    },
    readOnly: true,
  }, async (args, env) => {
    const rows = await ctx.activities.list(env.userId, args);
    return { activities: rows.map(brief) };
  });

  defineTool(server, ctx, "get_activity", {
    title: "Get activity",
    description:
      "Full summary of one activity: moving/elapsed time, distance, pace and cadence (both by moving time), HR, running dynamics (power, stride, vertical oscillation, ground contact), cycling power/cadence, swim pool length/strokes, weather (°C), analysis (GAP, time in zones, steady stretches, aerobic decoupling), laps/segments (distance, moving pace/speed, HR, power, cadence), the matched planned workout with targets in absolute units — compare plan and laps yourself, nothing is matched automatically — files. For curves use get_activity_streams.",
    input: { id: z.uuid() },
    readOnly: true,
  }, async ({ id }, env) => {
    const a = await ctx.activities.get(env.userId, id, { includeDeleted: true });
    if (!a) throw new ToolError("not_found", `activity ${id} not found`);
    const planned = a.plannedWorkoutId
      ? await ctx.docs.get<PlannedWorkout>(env.userId, "planned_workout", a.plannedWorkoutId)
      : null;
    const an = analysisOf(a.summary);
    const { analysis: _stored, ...summary } = a.summary;
    const now = await env.now();
    return {
      activity: {
        ...brief(a),
        summary,
        analysis: an
          ? await analysisView(
            an,
            a.sport,
            new ZoneContext(ctx, env, await env.profile(), now.date),
          )
          : null,
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
          structure: planned.data.structure && planned.data.sport !== "strength"
            ? resolveStructure(planned.data.structure, planned.data.sport, await env.profile())
            : planned.data.structure,
        }
        : null,
      files: (await ctx.activities.files(a.id)).map((f) => ({ kind: f.kind, bytes: f.bytes })),
      howToRead: [
        "elapsedSec = whole recording; movingSec = time actually moving (see summary.movingBasis: standing at a start line is excluded, walking counts). Pace uses movingSec; paceElapsedSecPerKm uses elapsed.",
        "Swim: paceSecPer100m uses the sum of swim lengths (rests excluded, confidence medium); paceWithRestsSecPer100m uses elapsed.",
        "detail 'summary_only' = the source (e.g. Strava's copy) wrote totals without HR/power/route. Indoor bike/treadmill distance is 'virtual' (from the trainer app) — compare power, not speed.",
        "hr avg/max come from HR samples (~every 5 s). startLocal is in the workout's own time zone.",
        "analysis: gapSecPerKm = grade-adjusted pace over moving time; zones = time in HR/power zones with the athlete's current zones (basis, confidence; polarization low/moderate/high); steady = stretches of steady aerobic state (HR ±6 bpm, ≥5 min) with HR, speed/GAP (m/s), power; decoupling = drift of output per bpm between the first and second half of the steady time (needs ≥40 min steady; <5 % = good aerobic endurance, >10 % = the effort was beyond the current aerobic base, or heat/dehydration).",
        "summary.intervals (and `intervals` in lists) = the athlete's manual intervals, when set; read them before whole-workout averages, which include warm-up/cool-down. Laps by kind: manual = intervals between markers the athlete set during the workout (often the real effort, e.g. a parkrun inside warm-up and cool-down) — listed first; segment = custom workout steps; lap = lap events; split_km = automatic km splits (mile splits dropped as duplicates). Pace and cadence in laps use moving time inside the lap. Nothing is matched to the plan automatically: the athlete may have run it differently, so compare plan.structure (targets resolved to absolute units) with laps and streams yourself.",
      ],
    };
  });

  defineTool(server, ctx, "get_activity_streams", {
    title: "Get activity streams",
    description:
      "Curves of one activity resampled into time buckets (default ~200 points; zoom with fromSec/toSec). Channels: heartRate, runningSpeed, runningPower, runningStrideLength, runningVerticalOscillation, runningGroundContactTime, cyclingPower, cyclingCadence, cyclingSpeed, cadence (run: spm from steps; bike: rpm), speed (m/s from distance, any sport), distance (cumulative m), altitude, lat, lon. Columns share the `t` axis (seconds from start).",
    input: {
      id: z.uuid(),
      channels: z.array(z.string()).min(1).max(8).default(["heartRate", "distance"]),
      fromSec: z.number().min(0).optional(),
      toSec: z.number().positive().optional(),
      maxPoints: z.number().int().min(10).max(600).optional(),
    },
    readOnly: true,
  }, async ({ id, channels, fromSec, toSec, maxPoints }, env) => {
    let dump;
    try {
      dump = await loadDump(ctx.activities, ctx.blobs, env.userId, id);
    } catch (err) {
      if (err instanceof NoStreamsError) throw new ToolError("no_streams", err.message);
      throw err;
    }
    if (!dump) throw new ToolError("not_found", `activity ${id} not found`);
    const from = fromSec ?? 0;
    const to = Math.min(toSec ?? dump.workout.durationSec, dump.workout.durationSec);
    if (to <= from) throw new ToolError("bad_range", "toSec must be > fromSec");
    const points = maxPoints ?? 200;
    const buckets = Math.max(1, Math.min(points, Math.ceil(to - from)));
    const data = streams(dump, channels, from, to, buckets);
    const available = [
      ...Object.keys(dump.samples),
      ...(dump.route.length ? ["lat", "lon", "altitude"] : []),
      ...(dump.samples.stepCount || dump.samples.cyclingCadence ? ["cadence"] : []),
      "distance",
      "speed",
    ];
    return {
      activityId: id,
      bucketSec: Math.round((to - from) / buckets * 10) / 10,
      columns: data,
      missing: channels.filter((ch) => !(ch in data)),
      available,
    };
  });
  defineTool(server, ctx, "link_activities", {
    title: "Link activities to planned workouts",
    description:
      "Set or clear which planned workout a recorded activity fulfils — the only way to fix plan↔fact links. New uploads are matched automatically (same date and sport), but workouts planned or imported after the activity arrived stay 'missed' until linked here; also use it to undo a wrong auto-match (plannedWorkoutId: null) or to move a link. Take ids from get_plan (days[].workouts and days[].activities). Several activities may fulfil one planned workout — a recording split in two (watch stopped and restarted), a cool-down written apart: link each of them to it. Batch is atomic; dryRun previews. Writes apply immediately and are logged in get_changes (filter by entityId = the activity id); revert_change(changeId) restores the previous link. Sport or date mismatch is allowed and comes back as a warning.",
    input: {
      links: z.array(z.object({
        activityId: z.uuid(),
        plannedWorkoutId: z.uuid().nullable().describe("null = unlink"),
      })).min(1).max(40),
      why: Why,
      dryRun: z.boolean().optional(),
    },
  }, async ({ links, why, dryRun }, env) => {
    const ids = links.map((l) => l.activityId);
    const dupId = ids.find((id, i) => ids.indexOf(id) !== i);
    if (dupId) throw new ToolError("bad_input", `activity ${dupId} appears twice in links`);
    const targets = [
      ...new Set(links.flatMap((l) => (l.plannedWorkoutId ? [l.plannedWorkoutId] : []))),
    ];

    const acts = new Map(
      (await ctx.activities.getMany(env.userId, ids)).filter((a) => !a.deletedAt).map((a) => [
        a.id,
        a,
      ]),
    );
    const planned = new Map(
      (await ctx.docs.getMany<PlannedWorkout>(env.userId, "planned_workout", targets)).map((d) => [
        d.id,
        d.data,
      ]),
    );

    const warnings: string[] = [];
    const changes: {
      activityId: string;
      previous: string | null;
      plannedWorkoutId: string | null;
    }[] = [];
    for (const l of links) {
      const a = acts.get(l.activityId);
      if (!a) throw new ToolError("not_found", `activity ${l.activityId} not found`);
      if (a.duplicateOf && l.plannedWorkoutId) {
        throw new ToolError(
          "conflict",
          `activity ${a.id} is a duplicate copy of ${a.duplicateOf}`,
          `Link the primary record ${a.duplicateOf} instead`,
        );
      }
      if (l.plannedWorkoutId) {
        const w = planned.get(l.plannedWorkoutId);
        if (!w) throw new ToolError("not_found", `planned workout ${l.plannedWorkoutId} not found`);
        if (w.sport !== a.sport) {
          warnings.push(`${a.id}: sport ${a.sport} ≠ planned ${w.sport} (${w.title})`);
        }
        if (w.date !== a.localDate) {
          warnings.push(`${a.id}: done ${a.localDate}, planned ${w.date} (${w.title})`);
        }
        if (w.skipped) warnings.push(`${w.id}: was marked skipped; status becomes done`);
      }
      if (a.plannedWorkoutId !== l.plannedWorkoutId) {
        changes.push({
          activityId: a.id,
          previous: a.plannedWorkoutId,
          plannedWorkoutId: l.plannedWorkoutId,
        });
      }
    }
    const unchanged = links.length - changes.length;
    if (dryRun || changes.length === 0) {
      return { dryRun: Boolean(dryRun), changes, unchanged, warnings };
    }

    await ctx.activities.relink(
      env.userId,
      changes.map((c) => ({ id: c.activityId, plannedId: c.plannedWorkoutId })),
    );
    const meta = await env.meta("link_activities", why);
    const out = [];
    for (const c of changes) {
      const changeId = await ctx.docs.logExternal(
        env.userId,
        meta,
        "activity",
        c.activityId,
        "update",
        { plannedWorkoutId: c.previous },
        { plannedWorkoutId: c.plannedWorkoutId },
      );
      out.push({ ...c, changeId });
    }
    return { changes: out, unchanged, warnings };
  });

  defineTool(server, ctx, "update_activity", {
    title: "Update activity notes",
    description:
      "Write on one recorded activity. coachNotes = your analysis of this session: what happened against the plan's goal, what it shows, what follows for the next sessions — conclusions about a single session go here, not into the week review or the journal. athleteNotes = the athlete's own words about this session (how it felt, what went wrong, recording errors); something that outlasts the session (pain for several days, new shoes, illness) goes to write_journal instead. rpe = the athlete's 1–10, never your estimate. Partial update: omitted fields stay, null clears. append=true adds the given notes text at the end instead of replacing. Read get_activity first. Writes immediately; logged in get_changes, revert_change restores the previous values.",
    input: {
      id: z.uuid(),
      coachNotes: z.string().min(1).max(COACH_NOTES_MAX).nullable().optional().describe(
        "Markdown, the athlete's language",
      ),
      athleteNotes: z.string().min(1).max(ATHLETE_NOTES_MAX).nullable().optional().describe(
        "The athlete's words, not yours",
      ),
      append: z.boolean().optional().describe(
        "Add coachNotes/athleteNotes text after the existing",
      ),
      title: z.string().min(1).max(80).nullable().optional(),
      rpe: z.number().int().min(1).max(10).nullable().optional(),
      tags: z.array(z.string().min(1).max(30)).max(10).optional().describe(
        "Replaces the list. Context (race, test) and surface: asphalt, trail, sand, snow, ice, mud, track, treadmill",
      ),
      why: Why.optional(),
    },
  }, async ({ id, append, why, ...fields }, env) => {
    const cur = await ctx.activities.get(env.userId, id);
    if (!cur) throw new ToolError("not_found", `activity ${id} not found`);
    const patch: ActivityAnnotations = {};
    for (const k of ANNOTATION_KEYS) {
      if (fields[k] !== undefined) (patch as Record<string, unknown>)[k] = fields[k];
    }
    if (Object.keys(patch).length === 0) {
      throw new ToolError("bad_input", "nothing to change", "Pass at least one field");
    }
    if (append) {
      for (
        const [k, max] of [["coachNotes", COACH_NOTES_MAX], [
          "athleteNotes",
          ATHLETE_NOTES_MAX,
        ]] as const
      ) {
        const add = patch[k];
        if (!add || !cur[k]) continue;
        const joined = `${cur[k]!.replace(/\s+$/, "")}\n\n${add}`;
        if (joined.length > max) {
          throw new ToolError(
            "too_long",
            `${k} would be ${joined.length} chars > ${max}`,
            "Condense the existing text and write it whole (append: false)",
          );
        }
        patch[k] = joined;
      }
    }
    const before: Record<string, unknown> = {};
    const after: Record<string, unknown> = {};
    for (const k of Object.keys(patch) as (keyof ActivityAnnotations)[]) {
      before[k] = cur[k];
      after[k] = patch[k] ?? null;
    }
    await ctx.activities.setAnnotations(env.userId, id, patch);
    const meta = await env.meta("update_activity", why);
    const changeId = await ctx.docs.logExternal(
      env.userId,
      meta,
      "activity",
      id,
      "update",
      before,
      after,
    );
    const row = (await ctx.activities.get(env.userId, id))!;
    return {
      activity: {
        ...brief(row),
        coachNotes: row.coachNotes ?? undefined,
        athleteNotes: row.athleteNotes ?? undefined,
        rpe: row.rpe ?? undefined,
        tags: row.tags,
      },
      changeId,
    };
  });
}
