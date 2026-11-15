import type { McpServer } from "@modelcontextprotocol/server";
import { z } from "zod";
import type {
  Event,
  JournalEntry,
  NotebookPage,
  PlannedWorkout,
  Week,
} from "../../domain/entities.ts";
import { PINNED_NOTEBOOK_LIMIT } from "../../domain/entities.ts";
import { estimate, workoutStatus } from "../../domain/plan.ts";
import { addDays, mondayOf } from "../../domain/time.ts";
import type { McpContext } from "../server.ts";
import { defineTool } from "../util.ts";

export function registerContextTool(server: McpServer, ctx: McpContext): void {
  defineTool(server, ctx, "get_context", {
    title: "Get coaching context",
    description:
      "CALL FIRST in every conversation (and again after a long pause). One call returns: athlete's local date/time and time zone (incl. travel), profile with thresholds, current and next week headers + recent week reviews, plan from yesterday to +7 days, races and race ideas, open journal items and the last 14 days of journal, pinned notebook pages in full + index of the rest, recent changes by any AI client.",
    input: {
      days: z.number().int().min(1).max(21).optional().describe("Plan horizon ahead, default 7"),
    },
    readOnly: true,
  }, async ({ days }, env) => {
    const userId = env.userId;
    const [profile, now] = [await env.profile(), await env.now()];
    const today = now.date;
    const monday = mondayOf(today);

    const [weeks, plan, events, journal, notebook, changes] = await Promise.all([
      ctx.docs.list<Week>(userId, "week"),
      ctx.docs.listByDate<PlannedWorkout>(
        userId,
        "planned_workout",
        addDays(today, -1),
        addDays(today, days ?? 7),
      ),
      ctx.docs.list<Event>(userId, "event"),
      ctx.docs.list<JournalEntry>(userId, "journal"),
      ctx.docs.list<NotebookPage>(userId, "notebook_page"),
      ctx.docs.changes(userId, { limit: 10 }),
    ]);
    const last = await ctx.docs.lastChanges(userId, "planned_workout", plan.map((d) => d.id));
    const done = await ctx.activities.byPlanned(userId, plan.map((d) => d.id));
    const lifted = await ctx.strength.donePlanned(userId, plan.map((d) => d.id));
    const recentActivities = await ctx.activities.list(userId, {
      from: addDays(today, -14),
      limit: 20,
    });

    const weekBy = new Map(weeks.map((w) => [w.data.weekStart, w.data]));
    const recentReviews = weeks.map((w) => w.data)
      .filter((w) => w.weekStart < monday && w.review)
      .sort((a, b) => b.weekStart.localeCompare(a.weekStart))
      .slice(0, 3)
      .map((w) => ({ weekStart: w.weekStart, title: w.title, review: w.review }));

    const days_ = new Map<string, unknown[]>();
    for (const d of plan) {
      const w = d.data;
      const est = w.structure && w.sport !== "strength"
        ? estimate(w.structure, w.sport, profile)
        : null;
      const lc = last.get(d.id);
      days_.set(w.date, [...(days_.get(w.date) ?? []), {
        id: w.id,
        order: w.order,
        sport: w.sport,
        title: w.title,
        goal: w.goal,
        key: w.key,
        execution: w.execution,
        status: workoutStatus(w, done.has(w.id) || lifted.has(w.id), today),
        activityId: done.get(w.id)?.id,
        skipReason: w.skipped?.reason,
        estimate: est ? { durationSec: est.durationSec, distanceM: est.distanceM } : undefined,
        lastChange: lc ? { at: lc.at, why: lc.why } : undefined,
      }]);
    }

    const ev = events.map((e) => e.data).filter((e) =>
      e.dateTo >= today && e.status !== "cancelled"
    )
      .sort((a, b) => a.dateFrom.localeCompare(b.dateFrom));
    const brief = (e: Event) => ({
      id: e.id,
      name: e.name,
      sport: e.sport,
      status: e.status,
      priority: e.priority,
      dateFrom: e.dateFrom,
      dateTo: e.dateTo,
      dateText: e.dateText,
      timezone: e.timezone,
      distanceM: e.distanceM,
      goal: e.goal,
    });

    const entries = journal.map((j) => j.data);
    const pinned = notebook.map((n) => n.data).filter((p) => p.pinned).sort((a, b) =>
      a.slug.localeCompare(b.slug)
    );
    let budget = PINNED_NOTEBOOK_LIMIT;
    const pinnedOut = pinned.map((p) => {
      const content = p.content.slice(0, Math.max(0, budget));
      budget -= p.content.length;
      return {
        slug: p.slug,
        title: p.title,
        content,
        truncated: content.length < p.content.length || undefined,
      };
    });
    const pinnedChars = pinned.reduce((n, p) => n + p.content.length, 0);

    return {
      profile,
      timezoneUnset: profile.timezone === "UTC" ? true : undefined,
      weeks: {
        current: weekBy.get(monday) ?? null,
        next: weekBy.get(addDays(monday, 7)) ?? null,
        recentReviews,
      },
      plan: [...days_.entries()].map(([date, workouts]) => ({ date, workouts })),
      events: {
        upcoming: ev.filter((e) => e.status !== "idea").map(brief),
        ideas: ev.filter((e) => e.status === "idea").map(brief),
      },
      journal: {
        open: entries.filter((e) => e.due && !e.closedAt).sort((a, b) =>
          (a.due ?? "").localeCompare(b.due ?? "")
        ),
        recent: entries.filter((e) => e.date >= addDays(today, -14) && !(e.due && !e.closedAt))
          .sort((a, b) => b.date.localeCompare(a.date)),
      },
      notebook: {
        pinned: pinnedOut,
        others: notebook.map((n) => n.data).filter((p) => !p.pinned).map((p) => ({
          slug: p.slug,
          title: p.title,
        })),
        ...(pinnedChars > PINNED_NOTEBOOK_LIMIT
          ? {
            warning:
              `Pinned pages total ${pinnedChars} chars > ${PINNED_NOTEBOOK_LIMIT}; content truncated. Unpin or condense.`,
          }
          : {}),
      },
      recentActivities: recentActivities.map((a) => {
        const s = a.summary as Record<string, unknown>;
        return {
          id: a.id,
          date: a.localDate,
          sport: a.sport,
          subSport: a.subSport ?? undefined,
          durationSec: a.durationSec,
          distanceM: a.distanceM ?? undefined,
          paceSecPerKm: s.paceSecPerKm ?? undefined,
          hrAvg: (s.hr as { avg?: number } | null)?.avg,
          plannedWorkoutId: a.plannedWorkoutId ?? undefined,
          athleteNotes: a.athleteNotes ?? undefined,
        };
      }),
      recentChanges: changes.map((c) => ({
        at: c.at,
        actor: c.actor,
        entity: c.entity,
        op: c.op,
        why: c.why,
        title: (c.after as { title?: string } | null)?.title ??
          (c.before as { title?: string } | null)?.title,
      })),
      howToRead: [
        "Dates are the athlete's local calendar dates in the effective time zone (home or travel).",
        timezoneUnset_hint(profile.timezone),
        "Workout status: done (activity matched) / skipped / missed (date passed; if an activity fits, link it with link_activities) / planned. recentActivities = last 14 days from Apple Health.",
        "Health metrics (HRV, sleep) and interval-level analysis are not connected yet.",
      ].filter(Boolean),
    };
  });
}

function timezoneUnset_hint(tz: string): string | null {
  return tz === "UTC"
    ? "Home time zone is not set (UTC). Ask the athlete where they live and call update_profile {timezone}."
    : null;
}
