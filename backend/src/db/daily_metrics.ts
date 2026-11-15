// Daily health metrics (resting HR, HRV, sleep, …) per athlete-local date. Scoped by user_id (rule 3).
import type { DailyMetrics, Sleep } from "../domain/readiness.ts";
import type { Sql } from "./client.ts";

export type { DailyMetrics, Sleep };

const day = (v: unknown) => (v instanceof Date ? v.toISOString().slice(0, 10) : String(v));
const num = (v: unknown) => (v === null || v === undefined ? null : Number(v));

export class DailyMetricsStore {
  constructor(readonly sql: Sql) {}

  /** Replace whole days (the phone recomputes each day from HealthKit). Returns rows written. */
  async upsert(userId: string, days: DailyMetrics[], deviceId: string | null): Promise<number> {
    if (days.length === 0) return 0;
    await this.sql.begin(async (tx) => {
      for (const d of days) {
        await tx`insert into zone2.daily_metrics
            (user_id, date, resting_hr, hrv_sdnn_ms, hrv_samples, sleep, respiratory_rate,
             wrist_temp_c, weight_kg, vo2max, device_id, updated_at)
          values (${userId}, ${d.date}, ${d.restingHr}, ${d.hrvSdnnMs}, ${d.hrvSamples},
             ${d.sleep ? tx.json(d.sleep as unknown as Parameters<typeof tx.json>[0]) : null},
             ${d.respiratoryRate}, ${d.wristTempC}, ${d.weightKg}, ${d.vo2max}, ${deviceId}, now())
          on conflict (user_id, date) do update set
            resting_hr = excluded.resting_hr, hrv_sdnn_ms = excluded.hrv_sdnn_ms,
            hrv_samples = excluded.hrv_samples, sleep = excluded.sleep,
            respiratory_rate = excluded.respiratory_rate, wrist_temp_c = excluded.wrist_temp_c,
            weight_kg = excluded.weight_kg, vo2max = excluded.vo2max,
            device_id = excluded.device_id, updated_at = now()`;
      }
    });
    return days.length;
  }

  /** Days in [from, to], oldest first. */
  async range(userId: string, from: string, to: string): Promise<DailyMetrics[]> {
    const rows = await this.sql`
      select date, resting_hr, hrv_sdnn_ms, hrv_samples, sleep, respiratory_rate, wrist_temp_c,
             weight_kg, vo2max
      from zone2.daily_metrics
      where user_id = ${userId} and date between ${from}::date and ${to}::date
      order by date`;
    return rows.map((r) => ({
      date: day(r.date),
      restingHr: num(r.resting_hr),
      hrvSdnnMs: num(r.hrv_sdnn_ms),
      hrvSamples: num(r.hrv_samples),
      sleep: (r.sleep as Sleep | null) ?? null,
      respiratoryRate: num(r.respiratory_rate),
      wristTempC: num(r.wrist_temp_c),
      weightKg: num(r.weight_kg),
      vo2max: num(r.vo2max),
    }));
  }
}
