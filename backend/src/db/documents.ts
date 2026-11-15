// Generic document store: every write goes through `mutate`, which records the change log and
// the sync feed in the same transaction. Revert = write the `before` snapshot back (D35).
import type { Sql } from "./client.ts";
import type postgres from "postgres";

export type Entity = "profile" | "week" | "planned_workout" | "event" | "journal" | "notebook_page";

export interface Doc<T = unknown> {
  id: string;
  data: T;
  version: number;
  deletedAt: Date | null;
  updatedAt: Date;
}

export interface ChangeMeta {
  actor: string;
  tool: string;
  why?: string | null;
}

export interface ChangeResult {
  changeId: string;
  entity: Entity;
  id: string;
  op: "create" | "update" | "delete";
  version: number;
}

export interface ChangeEntry {
  id: string;
  at: Date;
  actor: string;
  tool: string;
  entity: Entity;
  entityId: string;
  op: "create" | "update" | "delete";
  before: unknown;
  after: unknown;
  why: string | null;
  revertedBy: string | null;
}

export class NotFoundError extends Error {}
export class ConflictError extends Error {}

type Tx = postgres.TransactionSql | Sql;

// deno-lint-ignore no-explicit-any
const json = (sql: Tx, v: unknown) => sql.json(v as any);

function toDoc<T>(row: Record<string, unknown>): Doc<T> {
  return {
    id: row.id as string,
    data: row.data as T,
    version: row.version as number,
    deletedAt: row.deleted_at ? new Date(row.deleted_at as string) : null,
    updatedAt: new Date(row.updated_at as string),
  };
}

function toChange(r: Record<string, unknown>): ChangeEntry {
  return {
    id: r.id as string,
    at: new Date(r.at as string),
    actor: r.actor as string,
    tool: r.tool as string,
    entity: r.entity as Entity,
    entityId: r.entity_id as string,
    op: r.op as ChangeEntry["op"],
    before: r.before,
    after: r.after,
    why: (r.why as string | null) ?? null,
    revertedBy: (r.reverted_by as string | null) ?? null,
  };
}

export class DocumentStore {
  constructor(readonly sql: Sql) {}

  async transaction<T>(fn: (tx: postgres.TransactionSql) => Promise<T>): Promise<T> {
    return await this.sql.begin(fn) as T;
  }

  async get<T>(userId: string, entity: Entity, id: string, tx: Tx = this.sql) {
    const [row] = await tx`
      select id, data, version, deleted_at, updated_at from zone2.documents
      where user_id = ${userId} and entity = ${entity} and id = ${id} and deleted_at is null`;
    return row ? toDoc<T>(row) : null;
  }

  /** Like get, but also returns soft-deleted documents (deletedAt set). */
  async getIncludingDeleted<T>(userId: string, entity: Entity, id: string) {
    const [row] = await this.sql`
      select id, data, version, deleted_at, updated_at from zone2.documents
      where user_id = ${userId} and entity = ${entity} and id = ${id}`;
    return row ? toDoc<T>(row) : null;
  }

  async getMany<T>(userId: string, entity: Entity, ids: string[]) {
    if (ids.length === 0) return [];
    const rows = await this.sql`
      select id, data, version, deleted_at, updated_at from zone2.documents
      where user_id = ${userId} and entity = ${entity} and id = any(${ids}) and deleted_at is null`;
    return rows.map((r) => toDoc<T>(r));
  }

  /** Several (entity, id) pairs at once, including deleted ones. */
  async getPairs(userId: string, pairs: { entity: string; id: string }[]) {
    if (pairs.length === 0) return [];
    const rows = await this.sql`
      select entity, id, data, version, deleted_at, updated_at from zone2.documents
      where user_id = ${userId}
        and (entity, id) in (select * from unnest(${pairs.map((p) => p.entity)}::text[], ${
      pairs.map((p) => p.id)
    }::text[]))`;
    return rows.map((r) => ({ entity: r.entity as Entity, ...toDoc(r) }));
  }

  /** Live documents for a new device: undated entities whole, dated ones within [from, to]. */
  async snapshot(userId: string, from: string, to: string) {
    const rows = await this.sql`
      select entity, id, data, version, deleted_at, updated_at from zone2.documents
      where user_id = ${userId} and deleted_at is null
        and (entity in ('profile', 'event', 'notebook_page')
          or (entity = 'week' and id between ${from} and ${to})
          or (entity in ('planned_workout', 'journal') and data ->> 'date' between ${from} and ${to}))
      order by entity, id`;
    return rows.map((r) => ({ entity: r.entity as Entity, ...toDoc(r) }));
  }

  /** Live planned workouts from a date on (re-sent when the profile changes targets). */
  async plannedFrom(userId: string, from: string) {
    const rows = await this.sql`
      select 'planned_workout' as entity, id, data, version, deleted_at, updated_at from zone2.documents
      where user_id = ${userId} and entity = 'planned_workout' and deleted_at is null
        and data ->> 'date' >= ${from}`;
    return rows.map((r) => ({ entity: r.entity as Entity, ...toDoc(r) }));
  }

  async list<T>(userId: string, entity: Entity) {
    const rows = await this.sql`
      select id, data, version, deleted_at, updated_at from zone2.documents
      where user_id = ${userId} and entity = ${entity} and deleted_at is null
      order by id`;
    return rows.map((r) => toDoc<T>(r));
  }

  /** Documents whose data.date is within [from, to] (ISO dates compare as text). */
  async listByDate<T>(userId: string, entity: Entity, from: string, to: string) {
    const rows = await this.sql`
      select id, data, version, deleted_at, updated_at from zone2.documents
      where user_id = ${userId} and entity = ${entity} and deleted_at is null
        and data ->> 'date' between ${from} and ${to}
      order by data ->> 'date', (data ->> 'order')::int nulls last, id`;
    return rows.map((r) => toDoc<T>(r));
  }

  /** Create/update (`next` object) or soft-delete (`next` null). Records change log + sync feed. */
  async mutate(
    tx: postgres.TransactionSql,
    userId: string,
    entity: Entity,
    id: string,
    next: unknown | null,
    meta: ChangeMeta,
    opts: { implicitBefore?: unknown } = {},
  ): Promise<ChangeResult> {
    const [cur] = await tx`
      select data, version, deleted_at from zone2.documents
      where user_id = ${userId} and entity = ${entity} and id = ${id} for update`;
    // implicitBefore: documents that conceptually always exist (the profile with defaults) —
    // their first write is an update of the defaults, and reverting it restores the defaults.
    const before = cur && !cur.deleted_at ? cur.data : (opts.implicitBefore ?? null);
    let op: ChangeResult["op"];
    let version: number;

    if (next === null) {
      if (!before) throw new NotFoundError(`${entity} ${id} not found`);
      const [r] = await tx`
        update zone2.documents set deleted_at = now(), version = version + 1, updated_at = now()
        where user_id = ${userId} and entity = ${entity} and id = ${id} returning version`;
      op = "delete";
      version = r.version;
    } else if (!cur) {
      await tx`
        insert into zone2.documents (user_id, entity, id, data)
        values (${userId}, ${entity}, ${id}, ${json(tx, next)})`;
      op = "create";
      version = 1;
    } else {
      const [r] = await tx`
        update zone2.documents
        set data = ${json(tx, next)}, deleted_at = null, version = version + 1, updated_at = now()
        where user_id = ${userId} and entity = ${entity} and id = ${id} returning version`;
      op = before ? "update" : "create";
      version = r.version;
    }
    if (op === "create" && opts.implicitBefore !== undefined) op = "update";

    const [change] = await tx`
      insert into zone2.change_log (user_id, actor, tool, entity, entity_id, op, before, after, why)
      values (${userId}, ${meta.actor}, ${meta.tool}, ${entity}, ${id}, ${op},
              ${before === null ? null : json(tx, before)}, ${
      next === null ? null : json(tx, next)
    },
              ${meta.why ?? null})
      returning id`;
    await tx`
      insert into zone2.sync_feed (user_id, entity, entity_id, version, op)
      values (${userId}, ${entity}, ${id}, ${version}, ${next === null ? "delete" : "upsert"})`;
    return { changeId: change.id, entity, id, op, version };
  }

  /** Latest change (at, why) per entity id — for "changed 10.11: …" on cards. */
  async lastChanges(
    userId: string,
    entity: Entity,
    ids: string[],
  ): Promise<Map<string, { at: Date; why: string | null }>> {
    if (ids.length === 0) return new Map();
    const rows = await this.sql`
      select distinct on (entity_id) entity_id, at, why from zone2.change_log
      where user_id = ${userId} and entity = ${entity} and entity_id = any(${ids})
      order by entity_id, at desc`;
    return new Map(rows.map((r) => [r.entity_id as string, { at: new Date(r.at), why: r.why }]));
  }

  async changes(
    userId: string,
    opts: { since?: Date; entity?: Entity; entityId?: string; limit?: number } = {},
  ): Promise<ChangeEntry[]> {
    const limit = Math.min(opts.limit ?? 20, 100);
    const rows = await this.sql`
      select id, at, actor, tool, entity, entity_id, op, before, after, why, reverted_by
      from zone2.change_log
      where user_id = ${userId}
        ${opts.since ? this.sql`and at >= ${opts.since}` : this.sql``}
        ${opts.entity ? this.sql`and entity = ${opts.entity}` : this.sql``}
        ${opts.entityId ? this.sql`and entity_id = ${opts.entityId}` : this.sql``}
      order by at desc, id desc
      limit ${limit}`;
    return rows.map(toChange);
  }

  /** Writes the change's `before` back. Returns the new change and how many later edits it overrode. */
  async revert(
    userId: string,
    changeId: string,
    meta: ChangeMeta,
  ): Promise<{ result: ChangeResult; overriddenLaterChanges: number }> {
    return await this.transaction(async (tx) => {
      const [row] = await tx`
        select id, at, actor, tool, entity, entity_id, op, before, after, why, reverted_by
        from zone2.change_log where id = ${changeId} and user_id = ${userId} for update`;
      if (!row) throw new NotFoundError(`change ${changeId} not found`);
      const entry = toChange(row);
      if (entry.revertedBy) {
        throw new ConflictError(`change already reverted by ${entry.revertedBy}`);
      }
      // Compare in SQL: JS Date drops Postgres microseconds and would count the change itself.
      const [later] = await tx`
        select count(*)::int as n from zone2.change_log c
        where c.user_id = ${userId} and c.entity = ${entry.entity} and c.entity_id = ${entry.entityId}
          and c.id <> ${changeId}
          and c.at >= (select at from zone2.change_log where id = ${changeId})`;
      const result = await this.mutate(
        tx,
        userId,
        entry.entity,
        entry.entityId,
        entry.before ?? null,
        { ...meta, why: meta.why ?? `revert ${changeId}` },
      );
      await tx`update zone2.change_log set reverted_by = ${result.changeId} where id = ${changeId}`;
      return { result, overriddenLaterChanges: later.n };
    });
  }
}
