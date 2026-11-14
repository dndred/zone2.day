// Seeds a user with an access token and calls MCP tools over the real HTTP endpoint.
import { createApp } from "../../src/app.ts";
import { randomToken, sha256 } from "../../src/auth/crypto.ts";
import { AuthStore } from "../../src/auth/store.ts";
import type { Config } from "../../src/config.ts";
import { DocumentStore } from "../../src/db/documents.ts";
import { ActivityStore } from "../../src/db/activities.ts";
import { MemoryBlobStore } from "../../src/ports/blob.ts";
import type { AppDeps } from "../../src/deps.ts";
import { createTestDb, type TestDb } from "./db.ts";
import { fakePasskeys } from "./fake_passkeys.ts";

export const BASE = "https://api.test.zone2.day";
export const testConfig: Config = {
  env: "test",
  version: "test",
  publicBaseUrl: BASE,
  rpId: "zone2.day",
  secretKey: "x".repeat(40),
};

export interface McpHarness {
  db: TestDb;
  app: ReturnType<typeof createApp>;
  userId: string;
  token: string;
  appToken: string;
  /** POST to the Sync API with the app-scope token. */
  api: (path: string, body: BodyInit, type?: string) => Response | Promise<Response>;
  clock: { now: Date };
  // deno-lint-ignore no-explicit-any
  call: (tool: string, args?: Record<string, unknown>) => Promise<{ isError: boolean; data: any }>;
  // deno-lint-ignore no-explicit-any
  rpc: (method: string, params?: unknown) => Promise<any>;
  drop: () => Promise<void>;
}

export async function mcpHarness(
  opts: { now?: string; userName?: string } = {},
): Promise<McpHarness> {
  const db = await createTestDb();
  const clock = { now: new Date(opts.now ?? "2026-11-14T10:00:00Z") };
  const deps: AppDeps = {
    sql: db.sql,
    store: new AuthStore(db.sql),
    docs: new DocumentStore(db.sql),
    activities: new ActivityStore(db.sql),
    blobs: new MemoryBlobStore(),
    passkeys: fakePasskeys(),
    now: () => clock.now,
  };
  const app = createApp(testConfig, deps);
  const userId = crypto.randomUUID();
  const token = randomToken("z2a");
  await db.sql`insert into zone2.users (id, display_name) values (${userId}, ${
    opts.userName ?? "Andrei"
  })`;
  await db.sql`insert into zone2.oauth_clients (client_id, client_name, redirect_uris)
    values ('test-client', 'Claude', ${["https://claude.ai/cb"]})`;
  await db
    .sql`insert into zone2.oauth_tokens (token_hash, kind, client_id, user_id, scopes, resource, family_id, expires_at)
    values (${await sha256(token)}, 'access', 'test-client', ${userId}, ${[
    "mcp",
  ]}, ${`${BASE}/mcp`},
            ${crypto.randomUUID()}, now() + interval '3650 days')`;

  const appToken = randomToken("z2a");
  await db
    .sql`insert into zone2.oauth_tokens (token_hash, kind, client_id, user_id, scopes, resource, family_id, expires_at)
    values (${await sha256(appToken)}, 'access', 'zone2-ios', ${userId}, ${["app"]}, null,
            ${crypto.randomUUID()}, now() + interval '3650 days')`;
  const api = (path: string, body: BodyInit, type = "application/json") =>
    app.request(path, {
      method: "POST",
      headers: { "content-type": type, authorization: `Bearer ${appToken}` },
      body,
    });

  let id = 0;
  const rpc = async (method: string, params: unknown = {}) => {
    const res = await app.request("/mcp", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        accept: "application/json, text/event-stream",
        "mcp-protocol-version": "2025-06-18",
        authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params }),
    });
    return await res.json();
  };
  const call = async (tool: string, args: Record<string, unknown> = {}) => {
    const r = await rpc("tools/call", { name: tool, arguments: args });
    if (r.error) return { isError: true, data: r.error };
    const text = r.result.content?.[0]?.text ?? "null";
    let data: unknown;
    try {
      data = JSON.parse(text);
    } catch {
      data = text;
    }
    return { isError: Boolean(r.result.isError), data };
  };
  return { db, app, userId, token, appToken, api, clock, call, rpc, drop: () => db.drop() };
}
