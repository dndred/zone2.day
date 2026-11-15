// Completed activities (typed table). Annotations written by AI/athlete (title, notes, rpe, …) are
// never overwritten by re-ingesting the source.
import type { Sql } from "./client.ts";

export interface ActivityRow {
  id: string;
  source: string;
  sourceId: string;
  sourceApp: string | null;
  sport: string;
  subSport: string | null;
  activityType: number | null;
  startAt: Date;
  endAt: Date;
  timezone: string | null;
  localDate: string;
  durationSec: number;
  distanceM: number | null;
  summary: Record<string, unknown>;
  laps: unknown[];
  plannedWorkoutId: string | null;
  title: string | null;
  tags: string[];
  athleteNotes: string | null;
  coachNotes: string | null;
  rpe: number | null;
  official: unknown;
  grade: string | null;
  duplicateOf: string | null;
  version: number;
  deletedAt: Date | null;
}

export interface NewActivity {
  source: string;
  sourceId: string;
  sourceApp: string | null;
  sport: string;
  subSport: string | null;
  activityType: number | null;
  startAt: Date;
  endAt: Date;
  timezone: string | null;
  localDate: string;
  durationSec: number;
  distanceM: number | null;
  summary: Record<string, unknown>;
  laps: unknown[];
}

const COLS = `id, source, source_id, source_app, sport, sub_sport, activity_type, start_at, end_at,
  timezone, local_date::text as local_date, duration_sec, distance_m, summary, laps, planned_workout_id,
  title, tags, athlete_notes, coach_notes, rpe, official, grade, duplicate_of, version, deleted_at`;

function toRow(r: Record<string, unknown>): ActivityRow {
  return {
    id: r.id as string,
    source: r.source as string,
    sourceId: r.source_id as string,
    sourceApp: (r.source_app as string) ?? null,
    sport: r.sport as string,
    subSport: (r.sub_sport as string) ?? null,
    activityType: (r.activity_type as number) ?? null,
    startAt: new Date(r.start_at as string),
    endAt: new Date(r.end_at as string),
    timezone: (r.timezone as string) ?? null,
    localDate: r.local_date as string,
    durationSec: r.duration_sec as number,
    distanceM: r.distance_m === null ? null : Number(r.distance_m),
    summary: r.summary as Record<string, unknown>,
    laps: r.laps as unknown[],
    plannedWorkoutId: (r.planned_workout_id as string) ?? null,
    title: (r.title as string) ?? null,
    tags: (r.tags as string[]) ?? [],
    athleteNotes: (r.athlete_notes as string) ?? null,
    coachNotes: (r.coach_notes as string) ?? null,
    rpe: (r.rpe as number) ?? null,
    official: r.official ?? null,
    grade: (r.grade as string) ?? null,
    duplicateOf: (r.duplicate_of as string) ?? null,
    version: r.version as number,
    deletedAt: r.deleted_at ? new Date(r.deleted_at as string) : null,
  };
}

export class ActivityStore {
  constructor(readonly sql: Sql) {}

  private async feed(userId: string, id: string, version: number, op: "upsert" | "delete") {
    await this.sql`insert into zone2.sync_feed (user_id, entity, entity_id, version, op)
      values (${userId}, 'activity', ${id}, ${version}, ${op})`;
  }

  /** Insert or refresh source-derived fields (idempotent by source id). Undeletes if needed. */
  async upsert(userId: string, a: NewActivity): Promise<{ row: ActivityRow; created: boolean }> {
    const [r] = await this.sql.unsafe(
      `insert into zone2.activities (user_id, source, source_id, source_app, sport, sub_sport, activity_type,
        start_at, end_at, timezone, local_date, duration_sec, distance_m, summary, laps)
       values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)
       on conflict (user_id, source, source_id) do update set
         source_app = excluded.source_app, sport = excluded.sport, sub_sport = excluded.sub_sport,
         activity_type = excluded.activity_type, start_at = excluded.start_at, end_at = excluded.end_at,
         timezone = excluded.timezone, local_date = excluded.local_date, duration_sec = excluded.duration_sec,
         distance_m = excluded.distance_m, summary = excluded.summary, laps = excluded.laps,
         deleted_at = null, deleted_reason = null, version = zone2.activities.version + 1, updated_at = now()
       returning ${COLS}, (xmax = 0) as inserted`,
      [
        userId,
        a.source,
        a.sourceId,
        a.sourceApp,
        a.sport,
        a.subSport,
        a.activityType,
        a.startAt,
        a.endAt,
        a.timezone,
        a.localDate,
        a.durationSec,
        a.distanceM,
        // deno-lint-ignore no-explicit-any
        a.summary as any,
        // deno-lint-ignore no-explicit-any
        a.laps as any,
      ],
    );
    const row = toRow(r);
    await this.feed(userId, row.id, row.version, "upsert");
    return { row, created: Boolean(r.inserted) };
  }

  async get(userId: string, id: string, opts: { includeDeleted?: boolean } = {}) {
    const [r] = await this.sql.unsafe(
      `select ${COLS} from zone2.activities where user_id = $1 and id = $2 ${
        opts.includeDeleted ? "" : "and deleted_at is null"
      }`,
      [userId, id],
    );
    return r ? toRow(r) : null;
  }

  /** By ids, including deleted ones (the sync feed needs to tell the app about deletions). */
  async getMany(userId: string, ids: string[]): Promise<ActivityRow[]> {
    if (ids.length === 0) return [];
    const rows = await this.sql.unsafe(
      `select ${COLS} from zone2.activities where user_id = $1 and id = any($2::uuid[])`,
      [userId, ids],
    );
    return rows.map(toRow);
  }

  async list(
    userId: string,
    opts: {
      from?: string;
      to?: string;
      sport?: string;
      limit?: number;
      includeDuplicates?: boolean;
      includeRecovery?: boolean;
    },
  ): Promise<ActivityRow[]> {
    const rows = await this.sql.unsafe(
      `select ${COLS} from zone2.activities
       where user_id = $1 and deleted_at is null
         and ($2::date is null or local_date >= $2::date) and ($3::date is null or local_date <= $3::date)
         and ($4::text is null or sport = $4) and ($5::boolean or duplicate_of is null)
         and ($7::boolean or coalesce(summary ->> 'kind', 'training') <> 'recovery')
       order by start_at desc limit $6`,
      [
        userId,
        opts.from ?? null,
        opts.to ?? null,
        opts.sport ?? null,
        opts.includeDuplicates ?? false,
        opts.limit ?? 30,
        opts.includeRecovery ?? false,
      ],
    );
    return rows.map(toRow);
  }

  /**
   * Per-activity max HR since `from` (bike or everything else), for an observed max HR when the
   * profile has no HR model. Duplicates and recovery sessions are skipped.
   */
  async hrMaxima(userId: string, from: string, family: "run" | "bike"): Promise<number[]> {
    const rows = await this.sql.unsafe(
      `select (summary -> 'hr' ->> 'max')::float as max from zone2.activities
       where user_id = $1 and deleted_at is null and duplicate_of is null and local_date >= $2::date
         and (case when $3 = 'bike' then sport = 'bike' else sport <> 'bike' end)
         and coalesce(summary ->> 'kind', 'training') <> 'recovery'
         and summary -> 'hr' ->> 'max' is not null`,
      [userId, from, family],
    );
    return rows.map((r) => Number(r.max));
  }

  /** Matched (non-duplicate) activities for planned workout ids. */
  async byPlanned(userId: string, plannedIds: string[]): Promise<Map<string, ActivityRow>> {
    if (plannedIds.length === 0) return new Map();
    const rows = await this.sql.unsafe(
      `select ${COLS} from zone2.activities where user_id = $1 and deleted_at is null
         and duplicate_of is null and planned_workout_id = any($2::uuid[]) order by start_at`,
      [userId, plannedIds],
    );
    return new Map(rows.map((r) => [r.planned_workout_id as string, toRow(r)]));
  }

  async setPlanned(userId: string, id: string, plannedId: string | null) {
    const [r] = await this.sql`update zone2.activities set planned_workout_id = ${plannedId},
      version = version + 1, updated_at = now() where user_id = ${userId} and id = ${id} returning version`;
    if (r) await this.feed(userId, id, r.version, "upsert");
  }

  /** Set planned links for several activities in one transaction (all or nothing). */
  async relink(userId: string, links: { id: string; plannedId: string | null }[]) {
    await this.sql.begin(async (tx) => {
      for (const l of links) {
        const [r] = await tx`update zone2.activities set planned_workout_id = ${l.plannedId},
          version = version + 1, updated_at = now()
          where user_id = ${userId} and id = ${l.id} and deleted_at is null returning version`;
        if (!r) throw new Error(`activity ${l.id} vanished during relink`);
        await tx`insert into zone2.sync_feed (user_id, entity, entity_id, version, op)
          values (${userId}, 'activity', ${l.id}, ${r.version}, 'upsert')`;
      }
    });
  }

  async setDuplicate(userId: string, id: string, of: string | null) {
    const [r] = await this
      .sql`update zone2.activities set duplicate_of = ${of}, planned_workout_id = case when ${of}::uuid is null then planned_workout_id else null end,
      version = version + 1, updated_at = now() where user_id = ${userId} and id = ${id} returning version`;
    if (r) await this.feed(userId, id, r.version, "upsert");
  }

  /** Same-sport activities overlapping [start, end) by more than half of the shorter one. */
  async overlapping(userId: string, sport: string, start: Date, end: Date, excludeId: string) {
    const rows = await this.sql.unsafe(
      `select ${COLS} from zone2.activities where user_id = $1 and deleted_at is null and sport = $2 and id <> $5
         and start_at < $4 and end_at > $3
         and extract(epoch from (least(end_at, $4) - greatest(start_at, $3)))
             > 0.5 * least(extract(epoch from (end_at - start_at)), extract(epoch from ($4::timestamptz - $3::timestamptz)))`,
      [userId, sport, start, end, excludeId],
    );
    return rows.map(toRow);
  }

  async softDeleteBySource(userId: string, source: string, sourceIds: string[], reason: string) {
    if (sourceIds.length === 0) return [];
    const rows = await this
      .sql`update zone2.activities set deleted_at = now(), deleted_reason = ${reason},
        version = version + 1, updated_at = now()
      where user_id = ${userId} and source = ${source} and source_id = any(${sourceIds}) and deleted_at is null
      returning id, version`;
    for (const r of rows) await this.feed(userId, r.id, r.version, "delete");
    // Children that pointed at a deleted record are promoted back.
    await this.sql`update zone2.activities set duplicate_of = null, updated_at = now()
      where user_id = ${userId} and duplicate_of = any(${rows.map((r) => r.id)}::uuid[])`;
    return rows.map((r) => r.id as string);
  }

  /** Activities with a stored original whose summary was computed by an older summarize() (any user). */
  async outdatedSummaries(version: number, limit: number) {
    const rows = await this.sql`
      select a.id, a.user_id, a.planned_workout_id, f.storage_key, f.kind from zone2.activities a
      join zone2.activity_files f on f.activity_id = a.id and f.kind in ('healthkit_dump', 'fit_original')
      where a.deleted_at is null and coalesce((a.summary ->> 'v')::int, 1) < ${version}
      order by a.start_at desc limit ${limit}`;
    const [{ n }] = await this.sql`
      select count(*)::int as n from zone2.activities a
      join zone2.activity_files f on f.activity_id = a.id and f.kind in ('healthkit_dump', 'fit_original')
      where a.deleted_at is null and coalesce((a.summary ->> 'v')::int, 1) < ${version}`;
    return {
      items: rows.map((r) => ({
        id: r.id as string,
        userId: r.user_id as string,
        key: r.storage_key as string,
        kind: r.kind as "healthkit_dump" | "fit_original",
      })),
      remaining: n as number,
    };
  }

  /** Set the fields the athlete or coach wrote; omitted fields stay as they are. */
  async annotate(
    userId: string,
    id: string,
    a: { title?: string; tags?: string[]; athleteNotes?: string; rpe?: number },
  ) {
    const [r] = await this.sql`update zone2.activities set
        title = coalesce(${a.title ?? null}, title),
        tags = coalesce(${a.tags ?? null}::text[], tags),
        athlete_notes = coalesce(${a.athleteNotes ?? null}, athlete_notes),
        rpe = coalesce(${a.rpe ?? null}::smallint, rpe),
        version = version + 1, updated_at = now()
      where user_id = ${userId} and id = ${id} returning version`;
    if (r) await this.feed(userId, id, r.version, "upsert");
  }

  async addFile(
    activityId: string,
    f: { kind: string; key: string; bytes: number; sha256: string },
  ) {
    await this.sql`insert into zone2.activity_files (activity_id, kind, storage_key, bytes, sha256)
      values (${activityId}, ${f.kind}, ${f.key}, ${f.bytes}, ${f.sha256})
      on conflict (activity_id, kind) do update set storage_key = excluded.storage_key,
        bytes = excluded.bytes, sha256 = excluded.sha256, created_at = now()`;
  }

  async files(activityId: string) {
    const rows = await this.sql`select kind, storage_key, bytes, sha256, created_at
      from zone2.activity_files where activity_id = ${activityId} order by kind`;
    return rows.map((r) => ({
      kind: r.kind as string,
      key: r.storage_key as string,
      bytes: r.bytes as number,
      sha256: r.sha256 as string,
    }));
  }
}
