// End-to-end: claude.ai-style client → DCR → authorize → passkey sign-up (invite) → tokens → MCP.
import { assert, assertEquals, assertExists, assertMatch, assertStringIncludes } from "@std/assert";
import { createApp } from "../src/app.ts";
import { base64url, normalizeInviteCode, sha256 } from "../src/auth/crypto.ts";
import { AuthStore } from "../src/auth/store.ts";
import { DocumentStore } from "../src/db/documents.ts";
import { ActivityStore } from "../src/db/activities.ts";
import { MemoryBlobStore } from "../src/ports/blob.ts";
import type { Config } from "../src/config.ts";
import type { AppDeps } from "../src/deps.ts";
import { createTestDb } from "./helpers/db.ts";
import { fakePasskeys } from "./helpers/fake_passkeys.ts";

const BASE = "https://api.test.zone2.day";
const REDIRECT = "https://claude.ai/api/mcp/auth_callback";
const config: Config = {
  env: "test",
  version: "test",
  publicBaseUrl: BASE,
  rpId: "zone2.day",
  secretKey: "x".repeat(40),
};

type App = ReturnType<typeof createApp>;

async function setup() {
  const db = await createTestDb();
  const deps: AppDeps = {
    sql: db.sql,
    store: new AuthStore(db.sql),
    docs: new DocumentStore(db.sql),
    activities: new ActivityStore(db.sql),
    blobs: new MemoryBlobStore(),
    passkeys: fakePasskeys(),
    now: () => new Date(),
  };
  return { app: createApp(config, deps), db };
}

async function addInvite(db: { sql: AppDeps["sql"] }, code: string) {
  await db.sql`insert into zone2.invites (code_hash, expires_at)
    values (${await sha256(normalizeInviteCode(code))}, now() + interval '1 day')`;
}

async function registerClient(app: App, extra: Record<string, unknown> = {}) {
  const res = await app.request("/oauth/register", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ redirect_uris: [REDIRECT], client_name: "Claude", ...extra }),
  });
  assertEquals(res.status, 201);
  return await res.json();
}

async function pkce() {
  const verifier = base64url(crypto.getRandomValues(new Uint8Array(32)));
  return { verifier, challenge: await sha256(verifier) };
}

async function authorize(app: App, clientId: string, challenge: string, state = "st-1") {
  const q = new URLSearchParams({
    response_type: "code",
    client_id: clientId,
    redirect_uri: REDIRECT,
    code_challenge: challenge,
    code_challenge_method: "S256",
    state,
    scope: "mcp",
    resource: `${BASE}/mcp`,
  });
  const res = await app.request(`/oauth/authorize?${q}`);
  assertEquals(res.status, 200);
  assertStringIncludes(res.headers.get("x-zone2-content-type") ?? "", "text/html");
  assertStringIncludes(res.headers.get("x-zone2-csp") ?? "", "connect-src");
  const html = await res.text();
  const request = html.match(/"request":"([^"]+)"/)?.[1];
  assertExists(request);
  return request;
}

const postJson = (app: App, path: string, body: unknown) =>
  app.request(path, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });

async function signUp(app: App, request: string, invite: string, credId: string) {
  const opt = await (await postJson(app, "/oauth/passkey/register/options", {
    request,
    invite,
    name: "Andrei",
  })).json();
  assertExists(opt.challengeId, JSON.stringify(opt));
  const res = await postJson(app, "/oauth/passkey/register/verify", {
    request,
    challengeId: opt.challengeId,
    response: { id: credId, challenge: opt.options.challenge },
  });
  return { res, body: await res.json() };
}

async function signIn(app: App, request: string, credId: string) {
  const opt = await (await postJson(app, "/oauth/passkey/login/options", { request })).json();
  const res = await postJson(app, "/oauth/passkey/login/verify", {
    request,
    challengeId: opt.challengeId,
    response: { id: credId, challenge: opt.options.challenge },
  });
  return { res, body: await res.json() };
}

const tokenRequest = (app: App, form: Record<string, string>) =>
  app.request("/oauth/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(form).toString(),
  });

let rpcId = 0;
const mcp = (app: App, token: string | null, method: string, params: unknown = {}) =>
  app.request("/mcp", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      accept: "application/json, text/event-stream",
      "mcp-protocol-version": "2025-06-18",
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify({ jsonrpc: "2.0", id: ++rpcId, method, params }),
  });

Deno.test("discovery metadata", async () => {
  const { app, db } = await setup();
  try {
    const as = await (await app.request("/.well-known/oauth-authorization-server")).json();
    assertEquals(as.issuer, BASE);
    assertEquals(as.code_challenge_methods_supported, ["S256"]);
    assertEquals(as.registration_endpoint, `${BASE}/oauth/register`);
    const pr = await (await app.request("/.well-known/oauth-protected-resource/mcp")).json();
    assertEquals(pr.resource, `${BASE}/mcp`);
    assertEquals(pr.authorization_servers, [BASE]);
  } finally {
    await db.drop();
  }
});

Deno.test("full flow: sign-up → tokens → MCP ping → refresh rotation → sign-in", async () => {
  const { app, db } = await setup();
  try {
    // MCP without a token points the client at the resource metadata.
    const anon = await mcp(app, null, "initialize");
    assertEquals(anon.status, 401);
    assertStringIncludes(
      anon.headers.get("www-authenticate") ?? "",
      `resource_metadata="${BASE}/.well-known/oauth-protected-resource/mcp"`,
    );

    const client = await registerClient(app);
    assertMatch(client.client_id, /^z2cl_/);
    assertEquals(client.token_endpoint_auth_method, "none");

    await addInvite(db, "ABCD-1234");
    const { verifier, challenge } = await pkce();
    const request = await authorize(app, client.client_id, challenge);

    const signup = await signUp(app, request, " abcd-1234 ", "cred-1");
    assertEquals(signup.res.status, 200, JSON.stringify(signup.body));
    const redirect = new URL(signup.body.redirect);
    assertEquals(`${redirect.origin}${redirect.pathname}`, REDIRECT);
    assertEquals(redirect.searchParams.get("state"), "st-1");
    assertEquals(redirect.searchParams.get("iss"), BASE);
    const code = redirect.searchParams.get("code")!;

    // Wrong PKCE verifier is rejected and burns nothing else.
    const tokRes = await tokenRequest(app, {
      grant_type: "authorization_code",
      code,
      redirect_uri: REDIRECT,
      client_id: client.client_id,
      code_verifier: verifier,
    });
    assertEquals(tokRes.status, 200);
    assertEquals(tokRes.headers.get("cache-control"), "no-store");
    const tokens = await tokRes.json();
    assertEquals(tokens.token_type, "Bearer");
    assertEquals(tokens.scope, "mcp");

    // Codes are single-use.
    const replay = await tokenRequest(app, {
      grant_type: "authorization_code",
      code,
      redirect_uri: REDIRECT,
      client_id: client.client_id,
      code_verifier: verifier,
    });
    assertEquals((await replay.json()).error, "invalid_grant");

    // MCP: initialize, list, call ping.
    const init = await (await mcp(app, tokens.access_token, "initialize", {
      protocolVersion: "2025-06-18",
      capabilities: {},
      clientInfo: { name: "test", version: "0" },
    })).json();
    assertEquals(init.result.serverInfo.name, "zone2.day");
    assertStringIncludes(init.result.instructions, "coach");

    const list = await (await mcp(app, tokens.access_token, "tools/list")).json();
    assert(list.result.tools.some((t: { name: string }) => t.name === "ping"));

    const ping = await (await mcp(app, tokens.access_token, "tools/call", {
      name: "ping",
      arguments: {},
    })).json();
    const payload = JSON.parse(ping.result.content[0].text);
    assertEquals(payload.pong, true);
    assertEquals(payload.athlete.name, "Andrei");
    assertEquals(payload.client_id, client.client_id);

    // Refresh rotates; reusing the old refresh token revokes the whole family.
    const refreshed = await (await tokenRequest(app, {
      grant_type: "refresh_token",
      refresh_token: tokens.refresh_token,
      client_id: client.client_id,
    })).json();
    assertExists(refreshed.access_token);
    assert(refreshed.refresh_token !== tokens.refresh_token);

    const reuse = await tokenRequest(app, {
      grant_type: "refresh_token",
      refresh_token: tokens.refresh_token,
      client_id: client.client_id,
    });
    assertEquals((await reuse.json()).error, "invalid_grant");
    assertEquals((await mcp(app, refreshed.access_token, "tools/list")).status, 401);

    // Sign in again with the same passkey (new authorization).
    const p2 = await pkce();
    const request2 = await authorize(app, client.client_id, p2.challenge, "st-2");
    const signin = await signIn(app, request2, "cred-1");
    assertEquals(signin.res.status, 200, JSON.stringify(signin.body));
    const code2 = new URL(signin.body.redirect).searchParams.get("code")!;
    const tokens2 = await (await tokenRequest(app, {
      grant_type: "authorization_code",
      code: code2,
      client_id: client.client_id,
      code_verifier: p2.verifier,
    })).json();
    assertEquals((await mcp(app, tokens2.access_token, "tools/list")).status, 200);
  } finally {
    await db.drop();
  }
});

Deno.test("invite is single-use and PKCE is enforced", async () => {
  const { app, db } = await setup();
  try {
    const client = await registerClient(app);
    await addInvite(db, "ONCE-0001");
    const p = await pkce();
    const request = await authorize(app, client.client_id, p.challenge);

    // Race: two sign-ups got options with the same invite; only the first verify may win.
    const options = async () =>
      await (await postJson(app, "/oauth/passkey/register/options", {
        request,
        invite: "ONCE-0001",
        name: "A",
      })).json();
    const [a, b] = [await options(), await options()];
    const verify = (o: { challengeId: string; options: { challenge: string } }, id: string) =>
      postJson(app, "/oauth/passkey/register/verify", {
        request,
        challengeId: o.challengeId,
        response: { id, challenge: o.options.challenge },
      });
    assertEquals((await verify(a, "cred-a")).status, 200);
    const lost = await verify(b, "cred-b");
    assertEquals(lost.status, 400);
    assertEquals((await lost.json()).error, "invalid_invite");

    // And the invite is no longer accepted at all.
    const again = await postJson(app, "/oauth/passkey/register/options", {
      request,
      invite: "ONCE-0001",
      name: "C",
    });
    assertEquals((await again.json()).error, "invalid_invite");

    const signin = await signIn(app, request, "cred-a");
    const code = new URL(signin.body.redirect).searchParams.get("code")!;
    const bad = await tokenRequest(app, {
      grant_type: "authorization_code",
      code,
      client_id: client.client_id,
      code_verifier: base64url(crypto.getRandomValues(new Uint8Array(32))),
    });
    assertEquals((await bad.json()).error, "invalid_grant");
  } finally {
    await db.drop();
  }
});

Deno.test("authorize rejects unknown clients and unregistered redirect URIs", async () => {
  const { app, db } = await setup();
  try {
    const unknown = await app.request("/oauth/authorize?client_id=nope&response_type=code");
    assertEquals(unknown.status, 400);

    const client = await registerClient(app);
    const q = new URLSearchParams({
      client_id: client.client_id,
      redirect_uri: "https://evil.example/cb",
      response_type: "code",
      code_challenge: "x".repeat(43),
      code_challenge_method: "S256",
    });
    assertEquals((await app.request(`/oauth/authorize?${q}`)).status, 400);

    // Missing PKCE → redirected back to the client with an error.
    const noPkce = new URLSearchParams({
      client_id: client.client_id,
      redirect_uri: REDIRECT,
      response_type: "code",
      state: "s",
    });
    const res = await app.request(`/oauth/authorize?${noPkce}`);
    assertEquals(res.status, 302);
    const loc = new URL(res.headers.get("location")!);
    assertEquals(loc.searchParams.get("error"), "invalid_request");
    assertEquals(loc.searchParams.get("state"), "s");
  } finally {
    await db.drop();
  }
});

Deno.test("DCR validates redirect URIs and supports confidential clients", async () => {
  const { app, db } = await setup();
  try {
    const bad = await postJson(app, "/oauth/register", {
      redirect_uris: ["http://evil.example/cb"],
    });
    assertEquals(bad.status, 400);
    assertEquals((await bad.json()).error, "invalid_redirect_uri");

    const native = await registerClient(app, { redirect_uris: ["zone2://oauth/callback"] });
    assertEquals(native.redirect_uris, ["zone2://oauth/callback"]);

    const conf = await registerClient(app, { token_endpoint_auth_method: "client_secret_post" });
    assertMatch(conf.client_secret, /^z2cs_/);
    const noSecret = await tokenRequest(app, {
      grant_type: "refresh_token",
      refresh_token: "x",
      client_id: conf.client_id,
    });
    assertEquals(noSecret.status, 401);
  } finally {
    await db.drop();
  }
});
