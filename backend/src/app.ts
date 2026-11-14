import { Hono } from "@hono/hono";
import { cors } from "@hono/hono/cors";
import { verifyBearer } from "./auth/bearer.ts";
import { authRoutes, mcpResource } from "./auth/oauth.ts";
import type { Config } from "./config.ts";
import type { AppDeps } from "./deps.ts";
import type { AppEnv } from "./http.ts";
import { log } from "./log.ts";
import { handleMcpRequest } from "./mcp/server.ts";

export type { AppEnv } from "./http.ts";

/**
 * Builds the runtime-agnostic HTTP app. Entry points (local, Supabase, VPS) only wire it to a server.
 * Routes are mounted at the root: the edge proxy maps https://api.zone2.day/* here.
 * Without `deps` (no database configured) only /health is served.
 */
export function createApp(config: Config, deps?: AppDeps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();
  const base = config.publicBaseUrl;

  app.use("*", async (c, next) => {
    const requestId = c.req.header("x-request-id") ?? crypto.randomUUID();
    c.set("requestId", requestId);
    const started = performance.now();
    await next();
    c.header("x-request-id", requestId);
    // Supabase rewrites text/html → text/plain and replaces CSP with a sandbox on its domain.
    // Carry the real values in x-zone2-* so the edge proxy can restore them (no-op elsewhere).
    const type = c.res.headers.get("content-type");
    if (type?.startsWith("text/html")) {
      c.header("x-zone2-content-type", type);
      const csp = c.res.headers.get("content-security-policy");
      if (csp) c.header("x-zone2-csp", csp);
    }
    log("info", "request", {
      requestId,
      method: c.req.method,
      path: c.req.path,
      status: c.res.status,
      ms: Math.round(performance.now() - started),
      clientId: c.get("auth")?.clientId,
    });
  });

  // Browser-based MCP clients (e.g. MCP Inspector) need CORS; no cookies are used anywhere.
  const apiCors = cors({
    origin: "*",
    allowHeaders: [
      "Authorization",
      "Content-Type",
      "Mcp-Protocol-Version",
      "Mcp-Session-Id",
      "Last-Event-ID",
      "x-request-id",
    ],
    exposeHeaders: ["WWW-Authenticate", "Mcp-Session-Id", "x-request-id"],
  });
  app.use("/mcp", apiCors);
  app.use("/.well-known/*", apiCors);
  app.use("/oauth/token", apiCors);
  app.use("/oauth/register", apiCors);
  app.use("/oauth/revoke", apiCors);

  app.get("/health", (c) =>
    c.json({
      ok: true,
      service: "zone2-api",
      env: config.env,
      version: config.version,
      time: new Date().toISOString(),
    }));

  if (deps) {
    app.get("/health/db", async (c) => {
      const started = performance.now();
      await deps.sql`select 1`;
      return c.json({ ok: true, db: "ok", ms: Math.round(performance.now() - started) });
    });

    app.route("/", authRoutes(config, deps));

    app.all("/mcp", async (c) => {
      const result = await verifyBearer(deps.store, c.req.header("authorization"), {
        now: deps.now(),
        scope: "mcp",
        resource: mcpResource(base),
      });
      if (!result.ok) {
        const metadata = `${base}/.well-known/oauth-protected-resource/mcp`;
        const params = [`resource_metadata="${metadata}"`, `scope="mcp"`];
        if (result.error !== "missing") {
          params.push(
            `error="${
              result.error === "insufficient_scope" ? "insufficient_scope" : "invalid_token"
            }"`,
          );
        }
        c.header("WWW-Authenticate", `Bearer ${params.join(", ")}`);
        return c.json(
          { error: result.error === "missing" ? "unauthorized" : result.error },
          result.error === "insufficient_scope" ? 403 : 401,
        );
      }
      c.set("auth", result.auth);
      return await handleMcpRequest(c.req.raw, {
        config,
        auth: result.auth,
        store: deps.store,
        docs: deps.docs,
        now: deps.now,
      });
    });
  }

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
