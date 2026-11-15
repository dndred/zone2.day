// Devices and watch deliveries. Every query is scoped by user_id (rule 3).
import type { Sql } from "./client.ts";

export interface DeliveryReport {
  deviceId: string;
  deviceName?: string;
  model?: string;
  appVersion?: string;
  lastPullAt?: string;
  cursor?: string;
  watch: {
    error?: string | null;
    items: { plannedWorkoutId: string; version: number; date: string; warnings?: string[] }[];
  };
}

export interface DeliveryRow {
  plannedWorkoutId: string;
  deviceId: string;
  version: number;
  stage: "scheduled_watch" | "removed";
  date: string;
  warnings: string[];
  at: Date;
}

export interface DeviceRow {
  id: string;
  name: string | null;
  model: string | null;
  appVersion: string | null;
  lastSeenAt: Date;
  lastPullAt: Date | null;
  watchError: string | null;
  watchReportedAt: Date | null;
}

const iso = (v: unknown) => v instanceof Date ? v.toISOString().slice(0, 10) : String(v);

export class DeliveryStore {
  constructor(readonly sql: Sql) {}

  /** Snapshot from one device: listed → on the watch; its other scheduled rows → removed. */
  async report(
    userId: string,
    r: DeliveryReport,
    now: Date,
  ): Promise<{ onWatch: number; removed: number }> {
    return await this.sql.begin(async (tx) => {
      await tx`
        insert into zone2.devices (user_id, id, name, model, app_version, last_seen_at, last_pull_at, sync_cursor,
                                   watch_error, watch_reported_at)
        values (${userId}, ${r.deviceId}, ${r.deviceName ?? null}, ${r.model ?? null}, ${
        r.appVersion ?? null
      },
                ${now}, ${r.lastPullAt ?? null}, ${r.cursor ?? null}, ${
        r.watch.error ?? null
      }, ${now})
        on conflict (user_id, id) do update set
          name = coalesce(excluded.name, zone2.devices.name), model = coalesce(excluded.model, zone2.devices.model),
          app_version = coalesce(excluded.app_version, zone2.devices.app_version), last_seen_at = excluded.last_seen_at,
          last_pull_at = coalesce(excluded.last_pull_at, zone2.devices.last_pull_at),
          sync_cursor = coalesce(excluded.sync_cursor, zone2.devices.sync_cursor),
          watch_error = excluded.watch_error, watch_reported_at = excluded.watch_reported_at`;
      const ids = r.watch.items.map((i) => i.plannedWorkoutId);
      for (const i of r.watch.items) {
        await tx`
          insert into zone2.deliveries (user_id, planned_workout_id, device_id, version, stage, date, warnings, at)
          values (${userId}, ${i.plannedWorkoutId}, ${r.deviceId}, ${i.version}, 'scheduled_watch', ${i.date},
                  ${tx.json(i.warnings ?? [])}, ${now})
          on conflict (user_id, planned_workout_id, device_id) do update set
            version = excluded.version, stage = excluded.stage, date = excluded.date, warnings = excluded.warnings,
            at = case when zone2.deliveries.stage = excluded.stage and zone2.deliveries.version = excluded.version
                      then zone2.deliveries.at else excluded.at end`;
      }
      const removed = await tx`
        update zone2.deliveries set stage = 'removed', at = ${now}
        where user_id = ${userId} and device_id = ${r.deviceId} and stage = 'scheduled_watch'
          and not (planned_workout_id = any(${ids}))
        returning planned_workout_id`;
      return { onWatch: ids.length, removed: removed.length };
    });
  }

  async forWorkouts(userId: string, ids: string[]): Promise<DeliveryRow[]> {
    if (ids.length === 0) return [];
    const rows = await this.sql`
      select planned_workout_id, device_id, version, stage, date, warnings, at from zone2.deliveries
      where user_id = ${userId} and planned_workout_id = any(${ids})`;
    return rows.map((r) => ({
      plannedWorkoutId: r.planned_workout_id,
      deviceId: r.device_id,
      version: r.version,
      stage: r.stage,
      date: iso(r.date),
      warnings: r.warnings ?? [],
      at: new Date(r.at),
    }));
  }

  async devices(userId: string): Promise<DeviceRow[]> {
    const rows = await this.sql`
      select id, name, model, app_version, last_seen_at, last_pull_at, watch_error, watch_reported_at
      from zone2.devices where user_id = ${userId} order by last_seen_at desc`;
    return rows.map((r) => ({
      id: r.id,
      name: r.name,
      model: r.model,
      appVersion: r.app_version,
      lastSeenAt: new Date(r.last_seen_at),
      lastPullAt: r.last_pull_at ? new Date(r.last_pull_at) : null,
      watchError: r.watch_error,
      watchReportedAt: r.watch_reported_at ? new Date(r.watch_reported_at) : null,
    }));
  }
}
