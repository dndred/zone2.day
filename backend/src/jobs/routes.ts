// Maintenance jobs, called by CI after deploys (data migrations) and later by a scheduler.
// Protected by a shared secret header; without ZONE2_JOB_SECRET the routes do not exist.
import { Hono } from "@hono/hono";
import { timingSafeEqual } from "../auth/crypto.ts";
import type { Config } from "../config.ts";
import type { AppDeps } from "../deps.ts";
import type { AppEnv } from "../http.ts";
import { runDataMigrations } from "./data_migrations.ts";

export function jobRoutes(config: Config, deps: AppDeps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();

  app.use("/jobs/*", async (c, next) => {
    const given = c.req.header("x-zone2-job-secret") ?? "";
    if (!config.jobSecret || !timingSafeEqual(given, config.jobSecret)) {
      return c.json({ error: "not_found", path: c.req.path }, 404);
    }
    await next();
  });

  /** One batch of every pending data migration. Call until `remaining` is 0. */
  app.post("/jobs/data-migrations", async (c) => {
    const budget = Math.min(Number(c.req.query("batch") ?? 10), 50);
    return c.json(await runDataMigrations(deps, budget));
  });

  return app;
}
