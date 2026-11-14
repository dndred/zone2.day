// Maintenance jobs, called by a scheduler (pg_cron later) or `just` recipes. Shared secret header.
import { Hono } from "@hono/hono";
import { timingSafeEqual } from "../auth/crypto.ts";
import type { Config } from "../config.ts";
import type { AppDeps } from "../deps.ts";
import { SUMMARY_VERSION } from "../domain/healthkit.ts";
import type { AppEnv } from "../http.ts";
import { ingestHealthKit } from "../ingest/healthkit.ts";
import { log } from "../log.ts";

export function jobRoutes(config: Config, deps: AppDeps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();

  app.use("/jobs/*", async (c, next) => {
    const given = c.req.header("x-zone2-job-secret") ?? "";
    if (!config.jobSecret || !timingSafeEqual(given, config.jobSecret)) {
      return c.json({ error: "not_found", path: c.req.path }, 404);
    }
    await next();
  });

  /** Rebuild summaries computed by an older summarize() from the stored originals. Batch per call. */
  app.post("/jobs/recompute-summaries", async (c) => {
    const limit = Math.min(Number(c.req.query("limit") ?? 10), 50);
    const { items, remaining } = await deps.activities.outdatedSummaries(SUMMARY_VERSION, limit);
    let done = 0;
    const failed: string[] = [];
    for (const item of items) {
      try {
        const raw = await deps.blobs.get(item.key);
        if (!raw) throw new Error("original missing");
        await ingestHealthKit(deps, item.userId, raw, { storeOriginal: false });
        done++;
      } catch (err) {
        failed.push(item.id);
        log("warn", "job.recompute_failed", { activityId: item.id, error: String(err) });
      }
    }
    return c.json({
      processed: done,
      failed,
      remaining: remaining - done,
      version: SUMMARY_VERSION,
    });
  });

  return app;
}
