// Data migrations (D40): derived data that must be rebuilt when code changes, run like schema
// migrations — run on demand (`just job data-migrations` or a manual CI dispatch) until nothing is left.
// Each migration is idempotent, works in small batches and knows what is outdated by itself
// (e.g. summary.v < SUMMARY_VERSION), so it is safe to call any number of times.
import type { AppDeps } from "../deps.ts";
import { SUMMARY_VERSION } from "../domain/healthkit.ts";
import { ingestHealthKit } from "../ingest/healthkit.ts";
import { log } from "../log.ts";

export interface DataMigrationResult {
  name: string;
  processed: number;
  failed: string[];
  remaining: number;
}

export interface DataMigration {
  name: string;
  run(deps: AppDeps, limit: number): Promise<DataMigrationResult>;
}

/** Rebuild activity summaries/laps computed by an older summarize() from the stored originals. */
const activitySummaries: DataMigration = {
  name: `activity-summaries-v${SUMMARY_VERSION}`,
  async run(deps, limit) {
    const { items, remaining } = await deps.activities.outdatedSummaries(SUMMARY_VERSION, limit);
    let processed = 0;
    const failed: string[] = [];
    for (const item of items) {
      try {
        const raw = await deps.blobs.get(item.key);
        if (!raw) throw new Error("original missing");
        await ingestHealthKit(deps, item.userId, raw, { storeOriginal: false });
        processed++;
      } catch (err) {
        failed.push(item.id);
        log("warn", "data_migration.failed", {
          migration: this.name,
          id: item.id,
          error: String(err),
        });
      }
    }
    return { name: this.name, processed, failed, remaining: remaining - processed };
  },
};

/** In order. Add new ones at the end; remove them once every environment reports remaining 0. */
export const DATA_MIGRATIONS: DataMigration[] = [activitySummaries];

/** Runs migrations in order within a batch budget (Edge Function CPU limits → small batches). */
export async function runDataMigrations(deps: AppDeps, budget = 10) {
  const results: DataMigrationResult[] = [];
  let left = budget;
  for (const m of DATA_MIGRATIONS) {
    const r = await m.run(deps, Math.max(left, 0));
    results.push(r);
    left -= r.processed + r.failed.length;
  }
  const remaining = results.reduce((n, r) => n + r.remaining, 0);
  const processed = results.reduce((n, r) => n + r.processed, 0);
  return { processed, remaining, migrations: results };
}
