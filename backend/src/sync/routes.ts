// Sync API for the iOS app (docs/05-sync.md). Bearer tokens with scope "app".
import { Hono } from "@hono/hono";
import { z } from "zod";
import { verifyBearer } from "../auth/bearer.ts";
import type { Config } from "../config.ts";
import type { AppDeps } from "../deps.ts";
import type { AppEnv } from "../http.ts";
import { ingestHealthKit } from "../ingest/healthkit.ts";
import { log } from "../log.ts";

const MAX_UPLOAD_BYTES = 25 * 1024 * 1024;

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
