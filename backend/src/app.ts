import { Hono } from "@hono/hono";
import type { Config } from "./config.ts";
import { log } from "./log.ts";

export type AppEnv = { Variables: { requestId: string } };

/**
 * Builds the runtime-agnostic HTTP app. Entry points (local, Supabase, VPS) only wire it to a server.
 * Routes are mounted at the root: the edge proxy maps https://api.zone2.day/* here.
 */
export function createApp(config: Config): Hono<AppEnv> {
  const app = new Hono<AppEnv>();

  app.use("*", async (c, next) => {
    const requestId = c.req.header("x-request-id") ?? crypto.randomUUID();
    c.set("requestId", requestId);
    const started = performance.now();
    await next();
    c.header("x-request-id", requestId);
    log("info", "request", {
      requestId,
      method: c.req.method,
      path: c.req.path,
      status: c.res.status,
      ms: Math.round(performance.now() - started),
    });
  });

  app.get("/health", (c) =>
    c.json({
      ok: true,
      service: "zone2-api",
      env: config.env,
      version: config.version,
      time: new Date().toISOString(),
    }));

  app.notFound((c) => c.json({ error: "not_found", path: c.req.path }, 404));

  app.onError((err, c) => {
    log("error", "unhandled", {
      requestId: c.get("requestId"),
      path: c.req.path,
      error: err.message,
      stack: err.stack,
    });
    return c.json({ error: "internal", requestId: c.get("requestId") }, 500);
  });

  return app;
}
