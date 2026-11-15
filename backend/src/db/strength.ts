// Strength log: sessions → sets, exercises by name (aliases after merge_exercises).
// Every query is scoped by user_id (rule 3); ids come from the client, so writes also check
// that an existing row with that id belongs to the same user.
import type postgres from "postgres";
import type { Sql } from "./client.ts";

type Tx = postgres.TransactionSql | Sql;

export interface Load {
  [key: string]: number | null | undefined;
  reps?: number;
  weightKg?: number | null;
  holdSec?: number;
  distanceM?: number;
  rpe?: number;
}

export interface SetInput {
  id: string;
  exercise: string;
  order: number;
  setIndex: number;
  planned?: Load | null;
  actual?: Load | null;
  rpe?: number | null;
  note?: string | null;
  loggedAt?: string;
  deleted?: boolean;
}

export interface SessionInput {
  id: string;
  plannedWorkoutId?: string | null;
  date: string;
  notes?: string | null;
  sets: SetInput[];
  deleted?: boolean;
}

export interface StrengthSet {
  id: string;
  exercise: string;
  order: number;
  setIndex: number;
  planned: Load | null;
  actual: Load | null;
  rpe: number | null;
  note: string | null;
  loggedAt: string;
  source: string;
}

export interface StrengthSession {
  id: string;
  plannedWorkoutId: string | null;
  date: string;
  notes: string | null;
  source: string;
  version: number;
  deleted: boolean;
  sets: StrengthSet[];
}

export class ForeignIdError extends Error {}

const day = (v: unknown) => v instanceof Date ? v.toISOString().slice(0, 10) : String(v);

export class StrengthStore {
  constructor(readonly sql: Sql) {}

  /** Exercise id by name or alias (case-insensitive); creates it when new. */
  async exerciseId(tx: Tx, userId: string, name: string): Promise<string> {
    const clean = name.trim();
    const [found] = await tx`
      select id from zone2.exercises
      where user_id = ${userId}
        and (lower(name) = lower(${clean}) or lower(${clean}) = any(select lower(a) from unnest(aliases) a))
      limit 1`;
    if (found) return found.id;
    const [created] = await tx`
      insert into zone2.exercises (user_id, name) values (${userId}, ${clean})
      on conflict (user_id, lower(name)) do update set name = zone2.exercises.name
      returning id`;
    return created.id;
  }

  /**
   * Upsert a session snapshot and its sets (sets missing from `sets` stay as they are;
   * `deleted: true` removes one). Bumps the version and writes the sync feed.
   */
  async upsert(
    userId: string,
    s: SessionInput,
    source: "app" | "ai",
    now: Date,
  ): Promise<StrengthSession> {
    return await this.sql.begin(async (tx) => {
      const [own] = await tx`
        insert into zone2.strength_sessions (id, user_id, planned_workout_id, date, notes, source, updated_at, deleted_at)
        values (${s.id}, ${userId}, ${s.plannedWorkoutId ?? null}, ${s.date}, ${
        s.notes ?? null
      }, ${source}, ${now},
                ${s.deleted ? now : null})
        on conflict (id) do update set
          planned_workout_id = excluded.planned_workout_id, date = excluded.date,
          notes = coalesce(excluded.notes, zone2.strength_sessions.notes), updated_at = excluded.updated_at,
          deleted_at = excluded.deleted_at, version = zone2.strength_sessions.version + 1
        where zone2.strength_sessions.user_id = ${userId}
        returning version`;
      if (!own) throw new ForeignIdError(`session ${s.id} belongs to another user`);
      for (const set of s.sets) {
        const exerciseId = await this.exerciseId(tx, userId, set.exercise);
        const [ok] = await tx`
          insert into zone2.strength_sets (id, user_id, session_id, exercise_id, ord, set_index, planned, actual, rpe,
                                           note, logged_at, source, deleted_at)
          values (${set.id}, ${userId}, ${s.id}, ${exerciseId}, ${set.order}, ${set.setIndex},
                  ${set.planned ? tx.json({ ...set.planned }) : null}, ${
          set.actual ? tx.json({ ...set.actual }) : null
        },
                  ${set.rpe ?? null}, ${set.note ?? null}, ${
          set.loggedAt ?? now.toISOString()
        }, ${source},
                  ${set.deleted ? now : null})
          on conflict (id) do update set
            exercise_id = excluded.exercise_id, ord = excluded.ord, set_index = excluded.set_index,
            planned = excluded.planned, actual = excluded.actual, rpe = excluded.rpe, note = excluded.note,
            logged_at = excluded.logged_at, source = excluded.source, deleted_at = excluded.deleted_at
          where zone2.strength_sets.user_id = ${userId} and zone2.strength_sets.session_id = ${s.id}
          returning id`;
        if (!ok) throw new ForeignIdError(`set ${set.id} belongs to another session`);
      }
      await tx`insert into zone2.sync_feed (user_id, entity, entity_id, version, op)
        values (${userId}, 'strength_session', ${s.id}, ${own.version}, ${
        s.deleted ? "delete" : "upsert"
      })`;
      return (await this.load(tx, userId, [s.id], true))[0];
    });
  }

  private async load(
    tx: Tx,
    userId: string,
    ids: string[],
    includeDeleted: boolean,
  ): Promise<StrengthSession[]> {
    if (ids.length === 0) return [];
    const sessions = await tx`
      select id, planned_workout_id, date, notes, source, version, deleted_at from zone2.strength_sessions
      where user_id = ${userId} and id = any(${ids}::uuid[]) ${
      includeDeleted ? tx`` : tx`and deleted_at is null`
    }
      order by date, created_at`;
    const sets = await tx`
      select s.id, s.session_id, e.name as exercise, s.ord, s.set_index, s.planned, s.actual, s.rpe, s.note,
             s.logged_at, s.source
      from zone2.strength_sets s join zone2.exercises e on e.id = s.exercise_id
      where s.user_id = ${userId} and s.session_id = any(${ids}::uuid[]) and s.deleted_at is null
      order by s.ord, s.set_index`;
    return sessions.map((r) => ({
      id: r.id,
      plannedWorkoutId: r.planned_workout_id,
      date: day(r.date),
      notes: r.notes,
      source: r.source,
      version: r.version,
      deleted: r.deleted_at !== null,
      sets: sets.filter((x) => x.session_id === r.id).map((x) => ({
        id: x.id,
        exercise: x.exercise,
        order: x.ord,
        setIndex: x.set_index,
        planned: x.planned,
        actual: x.actual,
        rpe: x.rpe === null ? null : Number(x.rpe),
        note: x.note,
        loggedAt: new Date(x.logged_at).toISOString(),
        source: x.source,
      })),
    }));
  }

  async getMany(userId: string, ids: string[], opts: { includeDeleted?: boolean } = {}) {
    return await this.load(this.sql, userId, ids, opts.includeDeleted ?? false);
  }

  /** Sessions in [from, to], optionally only those with a given exercise. */
  async list(
    userId: string,
    opts: { from?: string; to?: string; exercise?: string; limit?: number },
  ) {
    const ids = await this.sql`
      select distinct ss.id, ss.date from zone2.strength_sessions ss
      left join zone2.strength_sets st on st.session_id = ss.id and st.deleted_at is null
      left join zone2.exercises e on e.id = st.exercise_id
      where ss.user_id = ${userId} and ss.deleted_at is null
        and (${opts.from ?? null}::date is null or ss.date >= ${opts.from ?? null}::date)
        and (${opts.to ?? null}::date is null or ss.date <= ${opts.to ?? null}::date)
        and (${opts.exercise ?? null}::text is null or lower(e.name) = lower(${
      opts.exercise ?? null
    })
             or lower(${opts.exercise ?? null}) = any(select lower(a) from unnest(e.aliases) a))
      order by ss.date desc limit ${opts.limit ?? 30}`;
    return await this.load(this.sql, userId, ids.map((r) => r.id), false);
  }

  /** Canonical name and aliases of an exercise (or just the given name if unknown). */
  async names(userId: string, exercise: string): Promise<string[]> {
    const [row] = await this.sql`
      select name, aliases from zone2.exercises
      where user_id = ${userId}
        and (lower(name) = lower(${exercise.trim()}) or lower(${exercise.trim()}) = any(select lower(a) from unnest(aliases) a))
      limit 1`;
    return row ? [row.name, ...row.aliases] : [exercise.trim()];
  }

  /** Planned workout ids that have a session with at least one done set. */
  async donePlanned(userId: string, plannedIds: string[]): Promise<Set<string>> {
    if (plannedIds.length === 0) return new Set();
    const rows = await this.sql`
      select distinct ss.planned_workout_id from zone2.strength_sessions ss
      join zone2.strength_sets st on st.session_id = ss.id and st.deleted_at is null and st.actual is not null
      where ss.user_id = ${userId} and ss.deleted_at is null and ss.planned_workout_id = any(${plannedIds})`;
    return new Set(rows.map((r) => r.planned_workout_id));
  }

  /** Merge exercises: sets of `names` move to `into` (created if needed); names become aliases. */
  async merge(
    userId: string,
    names: string[],
    into: string,
  ): Promise<{ into: string; movedSets: number }> {
    return await this.sql.begin(async (tx) => {
      const target = await this.exerciseId(tx, userId, into);
      const others = await tx`
        select id, name, aliases from zone2.exercises
        where user_id = ${userId} and id <> ${target}
          and lower(name) = any(${names.map((n) => n.trim().toLowerCase())})`;
      let moved = 0;
      for (const o of others) {
        const r = await tx`update zone2.strength_sets set exercise_id = ${target}
          where user_id = ${userId} and exercise_id = ${o.id} returning id`;
        moved += r.length;
        await tx`update zone2.exercises set aliases = array(select distinct unnest(aliases || ${[
          o.name,
          ...o.aliases,
        ]}::text[]))
          where id = ${target} and user_id = ${userId}`;
        await tx`delete from zone2.exercises where id = ${o.id} and user_id = ${userId}`;
      }
      // Sessions whose sets changed name go to the feed so the app shows the merged name.
      const touched = await tx`
        select distinct ss.id, ss.version from zone2.strength_sessions ss
        join zone2.strength_sets st on st.session_id = ss.id
        where ss.user_id = ${userId} and st.exercise_id = ${target}`;
      for (const t of touched) {
        await tx`update zone2.strength_sessions set version = version + 1 where id = ${t.id} and user_id = ${userId}`;
        await tx`insert into zone2.sync_feed (user_id, entity, entity_id, version, op)
          values (${userId}, 'strength_session', ${t.id}, ${t.version + 1}, 'upsert')`;
      }
      return {
        into: (await tx`select name from zone2.exercises where id = ${target}`)[0].name,
        movedSets: moved,
      };
    });
  }
}
