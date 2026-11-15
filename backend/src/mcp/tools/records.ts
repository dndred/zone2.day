// Profile, events, journal, notebook, change log.
import type { McpServer } from "@modelcontextprotocol/server";
import { z } from "zod";
import { DOCUMENT_ENTITIES, type Entity } from "../../db/documents.ts";
import {
  DEFAULT_PROFILE,
  Event,
  IsoDate,
  JournalEntry,
  NotebookPage,
  PINNED_NOTEBOOK_LIMIT,
  Profile,
  unknownProfileKeys,
} from "../../domain/entities.ts";
import type { McpContext } from "../server.ts";
import { defineTool, ToolError, Why } from "../util.ts";
import { revertExternal } from "./revert.ts";

const ENTITIES = [
  "profile",
  "week",
  "planned_workout",
  "event",
  "journal",
  "notebook_page",
] as const;

/** Thresholds where null is a stored value ("unknown"), not a removal. */
const NULLABLE_KEYS = new Set(["thresholdPaceSecPerKm", "lthr", "ftp", "cssSecPer100m"]);

export function registerRecordTools(server: McpServer, ctx: McpContext): void {
  // ---------------- profile ----------------
  defineTool(server, ctx, "get_profile", {
    title: "Get athlete profile",
    description:
      "Thresholds (number or range with basis), zones, home time zone and travel periods, equipment, notes.",
    input: {},
    readOnly: true,
  }, async (_args, env) => ({ profile: await env.profile() }));

  defineTool(server, ctx, "update_profile", {
    title: "Update athlete profile",
    description:
      "Partial update. Nested objects (run/bike/swim/zoneModel/equipment) are merged key by key; `travel` is replaced as a whole list; null removes a field. Only known fields are accepted (see get_profile; e.g. run.thresholdPaceSecPerKm, run.lthr, bike.ftp, swim.cssSecPer100m) — an unknown one fails with a suggestion. Thresholds: number or {low, high, basis}. Zones (run.hrZones, bike.hrZones, bike.powerZones): lower bounds of zones 2…n, e.g. hrZones [130,145,160,172] = Z1 <130 … Z5 ≥172; without them zones come from LTHR (Friel), max HR or FTP (Coggan). Change thresholds only after the athlete agrees. Travel periods set the effective time zone for plan dates on those days.",
    input: {
      patch: z.record(z.string(), z.unknown()).describe(
        "Fields to change, e.g. {timezone:'Asia/Barnaul'} or {run:{lthr:{low:156,high:162,basis:'…'}}} or {travel:[{from,to,timezone,note}]}",
      ),
      why: Why,
    },
  }, async ({ patch, why }, env) => {
    const unknown = unknownProfileKeys(patch);
    if (unknown.length) {
      throw new ToolError(
        "unknown_field",
        `unknown profile field${unknown.length > 1 ? "s" : ""}: ${
          unknown.map((u) => u.path).join(", ")
        }; nothing was saved`,
        unknown.map((u) =>
          u.suggestion
            ? `${u.path} → ${u.path.replace(/[^.]+$/, u.suggestion)}`
            : `${u.path}: not a profile field`
        ).join("; ") + ". Free-form facts go to notes or equipment.",
      );
    }
    const cur = await env.profile();
    const merged: Record<string, unknown> = { ...cur };
    // null removes a key (also inside run/bike/swim/zoneModel).
    const apply = (target: Record<string, unknown>, k: string, v: unknown) => {
      if (v === null && !NULLABLE_KEYS.has(k)) delete target[k];
      else target[k] = v;
    };
    for (const [k, v] of Object.entries(patch)) {
      const old = merged[k];
      if (
        v && typeof v === "object" && !Array.isArray(v) && old && typeof old === "object" &&
        !Array.isArray(old)
      ) {
        const next: Record<string, unknown> = { ...old };
        for (const [kk, vv] of Object.entries(v)) apply(next, kk, vv);
        merged[k] = next;
      } else apply(merged, k, v);
    }
    const profile = Profile.parse(merged);
    const meta = await env.meta("update_profile", why);
    const r = await ctx.docs.transaction((tx) =>
      ctx.docs.mutate(tx, env.userId, "profile", "profile", profile, meta, {
        implicitBefore: DEFAULT_PROFILE,
      })
    );
    env.setProfile(profile);
    return { profile, changeId: r.changeId };
  });

  // ---------------- events ----------------
  defineTool(server, ctx, "list_events", {
    title: "List events",
    description:
      "Races and race ideas. status: idea (interesting, no decision) | planned | registered | done | dnf | cancelled. Inexact dates come as a window dateFrom..dateTo with datePrecision and the athlete's own words in dateText.",
    input: {
      status: z.array(z.enum(["idea", "planned", "registered", "done", "dnf", "cancelled"]))
        .optional(),
      includePast: z.boolean().optional(),
    },
    readOnly: true,
  }, async ({ status, includePast }, env) => {
    const today = (await env.now()).date;
    const all = (await ctx.docs.list<Event>(env.userId, "event")).map((d) => d.data);
    const events = all
      .filter((e) => (status ? status.includes(e.status) : e.status !== "cancelled"))
      .filter((e) => includePast || e.dateTo >= today)
      .sort((a, b) => a.dateFrom.localeCompare(b.dateFrom));
    return { events };
  });

  defineTool(server, ctx, "upsert_event", {
    title: "Create or update event",
    description:
      "Create (no id) or partially update an event. Idea → decision = change status. Exact date: datePrecision 'day' with dateFrom = dateTo. Notes (≤20000, markdown) hold race plan, pacing, fueling. Put place in name/notes.",
    input: {
      id: z.uuid().optional(),
      fields: z.record(z.string(), z.unknown()).describe(
        "Event fields: name, sport, status, datePrecision, dateFrom, dateTo, dateText, startTime, timezone, distanceM, format, priority, goal, url, notes, result, notebookRefs",
      ),
      why: Why.optional(),
    },
  }, async ({ id, fields, why }, env) => {
    const cur = id ? await ctx.docs.get<Event>(env.userId, "event", id) : null;
    if (id && !cur) throw new ToolError("not_found", `event ${id} not found`);
    const event = Event.parse({ ...(cur?.data ?? {}), ...fields, id: id ?? crypto.randomUUID() });
    const meta = await env.meta("upsert_event", why);
    const r = await ctx.docs.transaction((tx) =>
      ctx.docs.mutate(tx, env.userId, "event", event.id, event, meta)
    );
    return { event, changeId: r.changeId };
  });

  defineTool(server, ctx, "delete_event", {
    title: "Delete event",
    description:
      "Delete an event (soft, undo with revert_change). Prefer status 'cancelled' to keep history.",
    input: { id: z.uuid(), why: Why },
    destructive: true,
  }, async ({ id, why }, env) => {
    const meta = await env.meta("delete_event", why);
    const r = await ctx.docs.transaction((tx) =>
      ctx.docs.mutate(tx, env.userId, "event", id, null, meta)
    );
    return { deleted: id, changeId: r.changeId };
  });

  // ---------------- journal ----------------
  defineTool(server, ctx, "list_journal", {
    title: "List journal",
    description:
      "Athlete journal: days without activity, symptoms (tags: migraine, soreness, pain, illness, sleep, stress), travel, gear, bike-fit, open questions. open=true → entries with a due date that are not closed.",
    input: {
      from: IsoDate.optional(),
      to: IsoDate.optional(),
      tags: z.array(z.string()).optional(),
      open: z.boolean().optional(),
    },
    readOnly: true,
  }, async ({ from, to, tags, open }, env) => {
    const today = (await env.now()).date;
    const docs = open
      ? await ctx.docs.list<JournalEntry>(env.userId, "journal")
      : await ctx.docs.listByDate<JournalEntry>(
        env.userId,
        "journal",
        from ?? "0000-01-01",
        to ?? today,
      );
    const entries = docs.map((d) => d.data)
      .filter((e) => !open || (e.due && !e.closedAt))
      .filter((e) => !tags?.length || tags.some((t) => e.tags.includes(t)))
      .sort((a, b) => a.date.localeCompare(b.date));
    return { entries };
  });

  defineTool(server, ctx, "write_journal", {
    title: "Write journal entry",
    description:
      "Create (no id) or update a journal entry. An entry with `due` stays open (shown in get_context) until closed with close=true. Write the athlete's facts in their words.",
    input: {
      id: z.uuid().optional(),
      date: IsoDate.optional(),
      text: z.string().min(1).max(4000).optional(),
      tags: z.array(z.string().max(30)).max(10).optional(),
      activityId: z.string().optional(),
      eventId: z.uuid().optional(),
      gearId: z.string().optional(),
      due: IsoDate.nullable().optional(),
      close: z.boolean().optional(),
    },
  }, async ({ id, close, due, ...fields }, env) => {
    const cur = id ? await ctx.docs.get<JournalEntry>(env.userId, "journal", id) : null;
    if (id && !cur) throw new ToolError("not_found", `journal entry ${id} not found`);
    const next: Record<string, unknown> = {
      ...(cur?.data ?? { date: (await env.now()).date }),
      ...Object.fromEntries(Object.entries(fields).filter(([, v]) => v !== undefined)),
      id: id ?? crypto.randomUUID(),
    };
    if (due === null) delete next.due;
    else if (due) next.due = due;
    if (close) next.closedAt = ctx.now().toISOString();
    const entry = JournalEntry.parse(next);
    const meta = await env.meta("write_journal");
    const r = await ctx.docs.transaction((tx) =>
      ctx.docs.mutate(tx, env.userId, "journal", entry.id, entry, meta)
    );
    return { entry, changeId: r.changeId };
  });

  // ---------------- notebook ----------------
  const pinnedChars = async (userId: string) =>
    (await ctx.docs.list<NotebookPage>(userId, "notebook_page"))
      .filter((d) => d.data.pinned)
      .reduce((n, d) => n + d.data.content.length, 0);

  defineTool(server, ctx, "list_notebook", {
    title: "List notebook",
    description:
      "Your long-term notebook about the athlete (markdown pages). Pinned pages are included verbatim in get_context. Suggested pages: athlete, principles, health (pinned); fuel, season, agreements.",
    input: {},
    readOnly: true,
  }, async (_args, env) => {
    const pages = (await ctx.docs.list<NotebookPage>(env.userId, "notebook_page")).map((d) => ({
      slug: d.data.slug,
      title: d.data.title,
      pinned: d.data.pinned,
      chars: d.data.content.length,
      updatedAt: d.updatedAt,
    }));
    return {
      pages,
      pinnedChars: await pinnedChars(env.userId),
      pinnedLimit: PINNED_NOTEBOOK_LIMIT,
    };
  });

  defineTool(server, ctx, "read_notebook", {
    title: "Read notebook page",
    description: "Full page content.",
    input: { slug: z.string() },
    readOnly: true,
  }, async ({ slug }, env) => {
    const doc = await ctx.docs.get<NotebookPage>(env.userId, "notebook_page", slug);
    if (!doc) throw new ToolError("not_found", `page '${slug}' not found`);
    return { page: doc.data, version: doc.version, updatedAt: doc.updatedAt };
  });

  defineTool(server, ctx, "write_notebook", {
    title: "Write notebook page",
    description:
      "Create or change a page. mode: replace (content = whole page) | append (content added at the end) | patch (replace exact text `find` with `content`). Pages sync to the athlete's phone (readable offline). Warns when pinned pages exceed the get_context budget.",
    input: {
      slug: z.string(),
      title: z.string().min(1).max(80).optional(),
      content: z.string().max(20_000),
      mode: z.enum(["replace", "append", "patch"]).default("replace"),
      find: z.string().optional(),
      pinned: z.boolean().optional(),
      why: Why.optional(),
    },
  }, async ({ slug, title, content, mode, find, pinned, why }, env) => {
    const cur = await ctx.docs.get<NotebookPage>(env.userId, "notebook_page", slug);
    let body = content;
    if (mode === "append") {
      body = cur ? `${cur.data.content.replace(/\s+$/, "")}\n\n${content}` : content;
    }
    if (mode === "patch") {
      if (!cur) throw new ToolError("not_found", `page '${slug}' not found`);
      if (!find || !cur.data.content.includes(find)) {
        throw new ToolError(
          "patch_failed",
          "`find` text not found in the page",
          "Read the page and copy the exact text.",
        );
      }
      body = cur.data.content.replace(find, content);
    }
    const page = NotebookPage.parse({
      slug,
      title: title ?? cur?.data.title ?? slug,
      content: body,
      pinned: pinned ?? cur?.data.pinned ?? false,
    });
    const meta = await env.meta("write_notebook", why);
    const r = await ctx.docs.transaction((tx) =>
      ctx.docs.mutate(tx, env.userId, "notebook_page", slug, page, meta)
    );
    const total = await pinnedChars(env.userId);
    return {
      page: { slug, title: page.title, pinned: page.pinned, chars: page.content.length },
      changeId: r.changeId,
      pinnedChars: total,
      ...(total > PINNED_NOTEBOOK_LIMIT
        ? {
          warning:
            `Pinned pages total ${total} chars > ${PINNED_NOTEBOOK_LIMIT}: get_context will truncate. Unpin or condense.`,
        }
        : {}),
    };
  });

  defineTool(server, ctx, "delete_notebook", {
    title: "Delete notebook page",
    description: "Delete a page (soft, undo with revert_change).",
    input: { slug: z.string(), why: Why },
    destructive: true,
  }, async ({ slug, why }, env) => {
    const meta = await env.meta("delete_notebook", why);
    const r = await ctx.docs.transaction((tx) =>
      ctx.docs.mutate(tx, env.userId, "notebook_page", slug, null, meta)
    );
    return { deleted: slug, changeId: r.changeId };
  });

  // ---------------- change log ----------------
  defineTool(server, ctx, "get_changes", {
    title: "Get change log",
    description:
      "Who changed what and why (all AI clients and the app). Use to see what another chat did, or to find a changeId for revert_change.",
    input: {
      since: z.iso.datetime().optional(),
      entity: z.enum(ENTITIES).optional(),
      entityId: z.string().optional(),
      limit: z.number().int().min(1).max(100).optional(),
    },
    readOnly: true,
  }, async ({ since, entity, entityId, limit }, env) => {
    const changes = await ctx.docs.changes(env.userId, {
      since: since ? new Date(since) : undefined,
      entity: entity as Entity | undefined,
      entityId,
      limit,
    });
    return {
      changes: changes.map((c) => ({
        changeId: c.id,
        at: c.at,
        actor: c.actor,
        tool: c.tool,
        entity: c.entity,
        entityId: c.entityId,
        op: c.op,
        why: c.why,
        revertedBy: c.revertedBy ?? undefined,
        title: (c.after as { title?: string } | null)?.title ??
          (c.before as { title?: string } | null)?.title,
      })),
    };
  });

  defineTool(server, ctx, "revert_change", {
    title: "Revert a change",
    description:
      "Undo one change by writing back the state before it (a create becomes a delete, a delete is restored). Works for plan, profile, events, journal, notebook, activities (a created activity is deleted, a link_activities change restores the previous link) and strength sessions (a logged session is deleted). Not revertable: edits of logged sets (fix with update_strength_log), merge_exercises, re-imports of a file. Later edits of the same item are overwritten — the result says how many.",
    input: { changeId: z.uuid(), why: Why },
  }, async ({ changeId, why }, env) => {
    const meta = await env.meta("revert_change", why);
    const entry = await ctx.docs.getChange(env.userId, changeId);
    if (!entry) throw new ToolError("not_found", `change ${changeId} not found`);
    if (!DOCUMENT_ENTITIES.includes(entry.entity)) {
      if (entry.revertedBy) {
        throw new ToolError("conflict", `change already reverted by ${entry.revertedBy}`);
      }
      const r = await revertExternal(ctx, env.userId, entry, {
        ...meta,
        why: meta.why ?? `revert ${changeId}`,
      });
      const overriddenLaterChanges = await ctx.docs.markReverted(
        env.userId,
        changeId,
        r.newChangeId,
      );
      return {
        reverted: changeId,
        newChangeId: r.newChangeId,
        entity: entry.entity,
        id: entry.entityId,
        op: r.op,
        overriddenLaterChanges,
        ...(r.warnings.length ? { warnings: r.warnings } : {}),
      };
    }
    const { result, overriddenLaterChanges } = await ctx.docs.revert(env.userId, changeId, meta);
    return {
      reverted: changeId,
      newChangeId: result.changeId,
      entity: result.entity,
      id: result.id,
      op: result.op,
      overriddenLaterChanges,
    };
  });
}
