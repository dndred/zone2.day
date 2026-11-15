// Pull side of the Sync API (docs/05-sync.md §2): a snapshot for a new device, then increments
// by cursor over zone2.sync_feed. The feed stores only "what changed"; data is read at fetch
// time, so several changes of one record collapse into its current state.
import type { ActivityRow } from "../db/activities.ts";
import type { Entity } from "../db/documents.ts";
import type { StrengthSession } from "../db/strength.ts";
import type { AppDeps } from "../deps.ts";
import { DEFAULT_PROFILE, type PlannedWorkout, Profile } from "../domain/entities.ts";
import { resolveStructure } from "../domain/plan.ts";
import { analysisOf } from "../domain/analysis.ts";
import { addDays, athleteNow } from "../domain/time.ts";
import { brief } from "../mcp/tools/activities.ts";

export const SNAPSHOT_PAST_DAYS = 90;
export const SNAPSHOT_FUTURE_DAYS = 60;

export interface SyncChange {
  entity: Entity | "activity" | "strength_session";
  id: string;
  op: "upsert" | "delete";
  version: number;
  data?: unknown;
}

export interface SyncPage {
  changes: SyncChange[];
  cursor: string;
  hasMore: boolean;
  snapshot: boolean;
  serverTime: string;
}

export class CursorGoneError extends Error {}

interface DocRow {
  entity: Entity;
  id: string;
  data: unknown;
  version: number;
  deletedAt: Date | null;
}

/** What the app stores for an activity: list fields + summary and laps (no streams). */
function activityData(a: ActivityRow) {
  return {
    ...brief(a),
    startAt: a.startAt.toISOString(),
    timezone: a.timezone,
    summary: slimSummary(a.summary),
    laps: a.laps,
    tags: a.tags,
    athleteNotes: a.athleteNotes,
    coachNotes: a.coachNotes,
    rpe: a.rpe,
    official: a.official,
    grade: a.grade,
  };
}

/** The app gets GAP and decoupling; histograms and steady segments stay on the server. */
function slimSummary(summary: Record<string, unknown>) {
  const an = analysisOf(summary);
  const { analysis: _a, ...rest } = summary;
  return an
    ? { ...rest, analysis: { gapSecPerKm: an.gapSecPerKm, decoupling: an.decoupling } }
    : rest;
}

/** Hidden from the app: deleted, or a worse copy of another activity (e.g. Strava's). */
const activityVisible = (a: ActivityRow) => !a.deletedAt && !a.duplicateOf;

type LastChanges = Map<string, { at: Date; why: string | null }>;

function docChange(d: DocRow, profile: Profile, last: LastChanges = new Map()): SyncChange {
  if (d.deletedAt) return { entity: d.entity, id: d.id, op: "delete", version: d.version };
  let data = d.data;
  if (d.entity === "planned_workout") {
    // Targets resolved to absolute units: the app builds watch workouts without its own resolver.
    // lastChange: "changed 10.11: <why>" on the card (docs/07-ios-app.md §3.1).
    const w = d.data as PlannedWorkout;
    const lc = last.get(d.id);
    data = {
      ...w,
      resolved: w.structure && w.sport !== "strength"
        ? resolveStructure(w.structure, w.sport, profile)
        : undefined,
      lastChange: lc ? { at: lc.at.toISOString(), why: lc.why } : undefined,
    };
  }
  return { entity: d.entity, id: d.id, op: "upsert", version: d.version, data };
}

function activityChange(a: ActivityRow): SyncChange {
  return activityVisible(a)
    ? { entity: "activity", id: a.id, op: "upsert", version: a.version, data: activityData(a) }
    : { entity: "activity", id: a.id, op: "delete", version: a.version };
}

function strengthChange(s: StrengthSession): SyncChange {
  return s.deleted
    ? { entity: "strength_session", id: s.id, op: "delete", version: s.version }
    : { entity: "strength_session", id: s.id, op: "upsert", version: s.version, data: s };
}

async function lastOf(deps: AppDeps, userId: string, docs: DocRow[]): Promise<LastChanges> {
  const ids = docs.filter((d) => d.entity === "planned_workout" && !d.deletedAt).map((d) => d.id);
  return await deps.docs.lastChanges(userId, "planned_workout", ids);
}

async function loadProfile(deps: AppDeps, userId: string): Promise<Profile> {
  const d = await deps.docs.get(userId, "profile", "profile");
  return d ? Profile.parse(d.data) : DEFAULT_PROFILE;
}

async function head(deps: AppDeps, userId: string): Promise<number> {
  const [r] = await deps.sql`
    select coalesce(max(seq), 0)::bigint as seq from zone2.sync_feed where user_id = ${userId}`;
  return Number(r.seq);
}

export async function syncPage(
  deps: AppDeps,
  userId: string,
  opts: { cursor: number | null; limit: number },
): Promise<SyncPage> {
  const serverTime = deps.now().toISOString();
  const profile = await loadProfile(deps, userId);
  const today = athleteNow(profile, deps.now()).date;

  if (opts.cursor === null) {
    // Head first: anything written while we read reappears in the next increment (idempotent).
    const cursor = await head(deps, userId);
    const from = addDays(today, -SNAPSHOT_PAST_DAYS);
    const docs = await deps.docs.snapshot(userId, from, addDays(today, SNAPSHOT_FUTURE_DAYS));
    const last = await lastOf(deps, userId, docs);
    const acts = await deps.activities.list(userId, {
      from,
      limit: 5000,
      includeRecovery: true,
    });
    const lifts = await deps.strength.list(userId, { from, limit: 500 });
    return {
      changes: [
        ...docs.map((d) => docChange(d, profile, last)),
        ...acts.map(activityChange),
        ...lifts.map((s) => strengthChange(s)),
      ],
      cursor: String(cursor),
      hasMore: false,
      snapshot: true,
      serverTime,
    };
  }

  const top = await head(deps, userId);
  if (opts.cursor > top) throw new CursorGoneError(`cursor ${opts.cursor} is ahead of ${top}`);
  const rows = await deps.sql`
    select seq, entity, entity_id from zone2.sync_feed
    where user_id = ${userId} and seq > ${opts.cursor}
    order by seq limit ${opts.limit + 1}`;
  const hasMore = rows.length > opts.limit;
  const page = rows.slice(0, opts.limit);
  const cursor = page.length ? Number(page[page.length - 1].seq) : opts.cursor;

  // Latest state per record; order of first appearance is irrelevant (each change is absolute).
  const docKeys = new Map<string, { entity: string; id: string }>();
  const actIds = new Set<string>();
  const liftIds = new Set<string>();
  for (const r of page) {
    if (r.entity === "activity") actIds.add(r.entity_id as string);
    else if (r.entity === "strength_session") liftIds.add(r.entity_id as string);
    else docKeys.set(`${r.entity}/${r.entity_id}`, { entity: r.entity, id: r.entity_id });
  }
  const docs = await deps.docs.getPairs(userId, [...docKeys.values()]);
  const last = await lastOf(deps, userId, docs);
  const changes = docs.map((d) => docChange(d, profile, last));
  // A profile change can move %-of-threshold targets: re-send upcoming workouts resolved anew.
  if (docKeys.has("profile/profile")) {
    const sent = new Set(docs.filter((d) => d.entity === "planned_workout").map((d) => d.id));
    const upcoming = await deps.docs.plannedFrom(userId, today);
    const lastUpcoming = await lastOf(deps, userId, upcoming);
    for (const d of upcoming) {
      if (!sent.has(d.id)) changes.push(docChange(d, profile, lastUpcoming));
    }
  }
  const acts = await deps.activities.getMany(userId, [...actIds]);
  changes.push(...acts.map(activityChange));
  const lifts = await deps.strength.getMany(userId, [...liftIds], { includeDeleted: true });
  changes.push(...lifts.map(strengthChange));
  return { changes, cursor: String(cursor), hasMore, snapshot: false, serverTime };
}
