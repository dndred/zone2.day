// Sync API for the iOS app (docs/05-sync.md). Bearer tokens with scope "app".
import { Hono } from "@hono/hono";
import { z } from "zod";
import { verifyBearer } from "../auth/bearer.ts";
import type { Config } from "../config.ts";
import type { AppDeps } from "../deps.ts";
import type { AppEnv } from "../http.ts";
import { ingestHealthKit } from "../ingest/healthkit.ts";
import { log } from "../log.ts";
import { CursorGoneError, syncPage } from "./feed.ts";

const MAX_UPLOAD_BYTES = 25 * 1024 * 1024;

const DeliveryBody = z.object({
  deviceId: z.string().min(8).max(64),
  deviceName: z.string().max(80).optional(),
  model: z.string().max(40).optional(),
  appVersion: z.string().max(20).optional(),
  lastPullAt: z.iso.datetime({ offset: true }).optional(),
  cursor: z.string().max(20).optional(),
  watch: z.object({
    error: z.string().max(200).nullable().optional(),
    items: z.array(z.object({
      plannedWorkoutId: z.string().min(1).max(64),
      version: z.number().int().positive(),
      date: z.iso.date(),
      warnings: z.array(z.string().max(300)).max(20).optional(),
    })).max(100),
  }),
});

export function syncRoutes(config: Config, deps: AppDeps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();

  app.use("/v1/*", async (c, next) => {
    const result = await verifyBearer(deps.store, c.req.header("authorization"), {
      now: deps.now(),
      scope: "app",
      resource: config.publicBaseUrl,
    });
    if (!result.ok) {
      c.header("WWW-Authenticate", `Bearer error="invalid_token", scope="app"`);
      return c.json({ error: result.error }, result.error === "insufficient_scope" ? 403 : 401);
    }
    c.set("auth", result.auth);
    await next();
  });

  app.get("/v1/me", async (c) => {
    const auth = c.get("auth")!;
    return c.json({ userId: auth.userId, name: await deps.store.getUserName(auth.userId) });
  });

  /**
   * Pull: no cursor → snapshot (−90…+60 days around today, profile, events, notebook);
   * with cursor → changes after it. Call again while hasMore. 410 → drop local data and resync.
   */
  app.get("/v1/sync", async (c) => {
    const auth = c.get("auth")!;
    const raw = c.req.query("cursor");
    if (raw !== undefined && !/^\d{1,18}$/.test(raw)) return c.json({ error: "bad_cursor" }, 400);
    const limit = Math.min(Math.max(Number(c.req.query("limit") ?? 500) || 500, 1), 1000);
    try {
      return c.json(
        await syncPage(deps, auth.userId, {
          cursor: raw === undefined ? null : Number(raw),
          limit,
        }),
      );
    } catch (err) {
      if (err instanceof CursorGoneError) return c.json({ error: "cursor_gone" }, 410);
      throw err;
    }
  });

  /** One HealthKit workout dump (JSON, optionally gzip). Idempotent by HKWorkout.uuid. */
  app.post("/v1/activities/healthkit", async (c) => {
    const auth = c.get("auth")!;
    const body = new Uint8Array(await c.req.arrayBuffer());
    if (body.length === 0) return c.json({ error: "empty_body" }, 400);
    if (body.length > MAX_UPLOAD_BYTES) return c.json({ error: "too_large" }, 413);
    try {
      const result = await ingestHealthKit(deps, auth.userId, body);
      log("info", "ingest.healthkit", { userId: auth.userId, ...result, bytes: body.length });
      return c.json(result, result.created ? 201 : 200);
    } catch (err) {
      if (err instanceof z.ZodError || err instanceof SyntaxError) {
        const issues = err instanceof z.ZodError
          ? err.issues.slice(0, 5).map((i) => `${i.path.join(".")}: ${i.message}`)
          : [err.message];
        return c.json({ error: "invalid_dump", issues }, 422);
      }
      throw err;
    }
  });

  /**
   * Watch delivery report from a device (docs/05-sync.md §5): a snapshot of planned workouts
   * scheduled on the watch right now, plus the device's sync state. Idempotent.
   */
  app.post("/v1/deliveries", async (c) => {
    const auth = c.get("auth")!;
    const parsed = DeliveryBody.safeParse(await c.req.json().catch(() => null));
    if (!parsed.success) {
      return c.json({
        error: "invalid_body",
        issues: parsed.error.issues.slice(0, 5).map((i) => i.message),
      }, 400);
    }
    return c.json(await deps.deliveries.report(auth.userId, parsed.data, deps.now()));
  });

  /** Workouts deleted in Apple Health (anchored query deletedObjects). */
  app.post("/v1/health-deletions", async (c) => {
    const auth = c.get("auth")!;
    const parsed = z.object({ uuids: z.array(z.string().min(1)).max(500) }).safeParse(
      await c.req.json().catch(() => null),
    );
    if (!parsed.success) return c.json({ error: "invalid_body" }, 400);
    const deleted = await deps.activities.softDeleteBySource(
      auth.userId,
      "healthkit",
      parsed.data.uuids,
      "health_deleted",
    );
    return c.json({ deleted: deleted.length });
  });

  return app;
}
