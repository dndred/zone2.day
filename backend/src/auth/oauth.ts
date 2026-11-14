// OAuth 2.1 Authorization Server for zone2.day (docs/02-architecture.md §6).
// Clients: claude.ai (DCR), iOS app (first-party), Claude Code. Login: passkeys; sign-up: invite.
import { Hono } from "@hono/hono";
import { z } from "zod";
import type { Config } from "../config.ts";
import type { AppContext, AppEnv } from "../http.ts";
import { log } from "../log.ts";
import {
  normalizeInviteCode,
  randomToken,
  sha256,
  signPayload,
  timingSafeEqual,
  verifyPayload,
  verifyPkceS256,
} from "./crypto.ts";
import { pickLang, renderAuthorizePage, renderErrorPage } from "./page.ts";
import type { PasskeyService } from "./passkeys.ts";
import type { AuthStore, OAuthClient, TokenEndpointAuthMethod } from "./store.ts";

export const ACCESS_TOKEN_TTL_SEC = 60 * 60;
export const REFRESH_TOKEN_TTL_SEC = 90 * 24 * 60 * 60;
const CODE_TTL_SEC = 10 * 60;
const CHALLENGE_TTL_SEC = 5 * 60;
const AUTH_REQUEST_TTL_SEC = 15 * 60;
export const SCOPES = ["mcp", "app"] as const;

export interface AuthDeps {
  store: AuthStore;
  passkeys: PasskeyService;
  now: () => Date;
}

/** Signed, short-lived copy of the /authorize query carried by the sign-in page. */
interface AuthRequest {
  cid: string;
  ru: string;
  cc: string;
  sc: string[];
  st?: string;
  rs?: string;
  exp: number;
}

export function authServerMetadata(base: string) {
  const methods = ["none", "client_secret_post", "client_secret_basic"];
  return {
    issuer: base,
    authorization_endpoint: `${base}/oauth/authorize`,
    token_endpoint: `${base}/oauth/token`,
    registration_endpoint: `${base}/oauth/register`,
    revocation_endpoint: `${base}/oauth/revoke`,
    response_types_supported: ["code"],
    grant_types_supported: ["authorization_code", "refresh_token"],
    code_challenge_methods_supported: ["S256"],
    token_endpoint_auth_methods_supported: methods,
    revocation_endpoint_auth_methods_supported: methods,
    scopes_supported: [...SCOPES],
    service_documentation: "https://github.com/dndred/zone2.day",
  };
}

export function protectedResourceMetadata(base: string) {
  return {
    resource: `${base}/mcp`,
    authorization_servers: [base],
    scopes_supported: ["mcp"],
    bearer_methods_supported: ["header"],
    resource_name: "zone2.day",
  };
}

export function mcpResource(base: string): string {
  return `${base}/mcp`;
}

const RegisterSchema = z.object({
  redirect_uris: z.array(z.string()).min(1).max(10),
  client_name: z.string().max(200).optional(),
  token_endpoint_auth_method: z.enum(["none", "client_secret_post", "client_secret_basic"])
    .optional(),
  grant_types: z.array(z.string()).optional(),
  response_types: z.array(z.string()).optional(),
  scope: z.string().optional(),
  client_uri: z.string().optional(),
  logo_uri: z.string().optional(),
});

function validRedirectUri(raw: string): boolean {
  let u: URL;
  try {
    u = new URL(raw);
  } catch {
    return false;
  }
  if (u.hash) return false;
  if (u.protocol === "https:") return true;
  if (u.protocol === "http:") return ["localhost", "127.0.0.1", "[::1]"].includes(u.hostname);
  // Native apps: private-use URI schemes (e.g. zone2://oauth/callback).
  return /^[a-z][a-z0-9+.-]*:$/.test(u.protocol) && !["javascript:", "data:", "file:"].includes(
    u.protocol,
  );
}

function oauthError(c: AppContext, status: 400 | 401, error: string, description?: string) {
  c.header("Cache-Control", "no-store");
  return c.json({ error, ...(description ? { error_description: description } : {}) }, status);
}

export function authRoutes(config: Config, deps: AuthDeps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();
  const base = config.publicBaseUrl;
  const { store, passkeys } = deps;
  const nowSec = () => Math.floor(deps.now().getTime() / 1000);

  const validResource = (r: string) => r === mcpResource(base) || r === base || r === `${base}/`;

  // ---------- discovery ----------
  app.get("/.well-known/oauth-authorization-server", (c) => c.json(authServerMetadata(base)));
  app.get("/.well-known/oauth-authorization-server/*", (c) => c.json(authServerMetadata(base)));
  app.get("/.well-known/openid-configuration", (c) => c.json(authServerMetadata(base)));
  app.get("/.well-known/oauth-protected-resource", (c) => c.json(protectedResourceMetadata(base)));
  app.get(
    "/.well-known/oauth-protected-resource/*",
    (c) => c.json(protectedResourceMetadata(base)),
  );

  // ---------- dynamic client registration (RFC 7591) ----------
  app.post("/oauth/register", async (c) => {
    const body = await c.req.json().catch(() => null);
    const parsed = RegisterSchema.safeParse(body);
    if (!parsed.success) {
      return oauthError(c, 400, "invalid_client_metadata", parsed.error.issues[0]?.message);
    }
    const meta = parsed.data;
    const bad = meta.redirect_uris.find((u) => !validRedirectUri(u));
    if (bad) return oauthError(c, 400, "invalid_redirect_uri", `Not allowed: ${bad}`);

    const method: TokenEndpointAuthMethod = meta.token_endpoint_auth_method ?? "none";
    const clientId = randomToken("z2cl", 16);
    const clientSecret = method === "none" ? null : randomToken("z2cs");
    await store.createClient({
      clientId,
      clientSecretHash: clientSecret ? await sha256(clientSecret) : null,
      clientName: meta.client_name ?? null,
      redirectUris: meta.redirect_uris,
      tokenEndpointAuthMethod: method,
      metadata: { client_uri: meta.client_uri, logo_uri: meta.logo_uri, scope: meta.scope },
    });
    log("info", "oauth.client_registered", { clientId, clientName: meta.client_name, method });
    c.header("Cache-Control", "no-store");
    return c.json({
      client_id: clientId,
      ...(clientSecret ? { client_secret: clientSecret, client_secret_expires_at: 0 } : {}),
      client_id_issued_at: nowSec(),
      client_name: meta.client_name,
      redirect_uris: meta.redirect_uris,
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
      token_endpoint_auth_method: method,
    }, 201);
  });

  // ---------- authorization endpoint ----------
  app.get("/oauth/authorize", async (c) => {
    const lang = pickLang(c.req.header("accept-language"));
    const q = c.req.query();
    const client = q.client_id ? await store.getClient(q.client_id) : null;
    if (!client) return c.html(renderErrorPage(lang, "Unknown client_id"), 400);
    const redirectUri = q.redirect_uri ??
      (client.redirectUris.length === 1 ? client.redirectUris[0] : undefined);
    if (!redirectUri || !client.redirectUris.includes(redirectUri)) {
      return c.html(renderErrorPage(lang, "redirect_uri is not registered for this client"), 400);
    }

    const fail = (error: string, description: string) => {
      const u = new URL(redirectUri);
      u.searchParams.set("error", error);
      u.searchParams.set("error_description", description);
      if (q.state) u.searchParams.set("state", q.state);
      u.searchParams.set("iss", base);
      return c.redirect(u.toString(), 302);
    };
    if (q.response_type !== "code") return fail("unsupported_response_type", "Only 'code'");
    if (!q.code_challenge || q.code_challenge_method !== "S256") {
      return fail("invalid_request", "PKCE with S256 is required");
    }
    const scopes = (q.scope ?? "mcp").split(/\s+/).filter(Boolean);
    if (scopes.length === 0 || scopes.some((s) => !(SCOPES as readonly string[]).includes(s))) {
      return fail("invalid_scope", `Supported scopes: ${SCOPES.join(" ")}`);
    }
    if (q.resource && !validResource(q.resource)) {
      return fail("invalid_target", "Unknown resource");
    }

    const request = await signPayload(
      {
        cid: client.clientId,
        ru: redirectUri,
        cc: q.code_challenge,
        sc: scopes,
        st: q.state,
        rs: q.resource,
        exp: nowSec() + AUTH_REQUEST_TTL_SEC,
      } satisfies AuthRequest,
      config.secretKey,
    );
    c.header("Cache-Control", "no-store");
    c.header(
      "Content-Security-Policy",
      `default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src ${
        new URL(base).origin
      }; form-action 'none'; frame-ancestors 'none'; base-uri 'none'`,
    );
    return c.html(
      renderAuthorizePage({
        lang,
        clientName: client.clientName ?? "An app",
        request,
        baseUrl: base,
      }),
    );
  });

  const readAuthRequest = async (c: AppContext) => {
    const body = await c.req.json().catch(() => null) as Record<string, unknown> | null;
    const token = typeof body?.request === "string" ? body.request : "";
    const req = await verifyPayload<AuthRequest>(token, config.secretKey, nowSec());
    return { body: body ?? {}, req };
  };

  const issueCode = async (req: AuthRequest, userId: string): Promise<string> => {
    const code = randomToken("z2c");
    await store.saveCode(await sha256(code), {
      clientId: req.cid,
      userId,
      redirectUri: req.ru,
      codeChallenge: req.cc,
      scopes: req.sc,
      resource: req.rs ?? null,
    }, CODE_TTL_SEC);
    const u = new URL(req.ru);
    u.searchParams.set("code", code);
    if (req.st) u.searchParams.set("state", req.st);
    u.searchParams.set("iss", base);
    return u.toString();
  };

  const expired = (c: AppContext) =>
    oauthError(c, 400, "expired_request", "The sign-in request expired. Start again.");

  // ---------- passkey sign-up (invite) ----------
  app.post("/oauth/passkey/register/options", async (c) => {
    const { body, req } = await readAuthRequest(c);
    if (!req) return expired(c);
    const name = String(body.name ?? "").trim();
    if (name.length < 1 || name.length > 60) {
      return oauthError(c, 400, "invalid_name", "Name: 1–60 characters");
    }
    const inviteHash = await sha256(normalizeInviteCode(String(body.invite ?? "")));
    if (!(await store.isInviteUsable(inviteHash))) {
      return oauthError(c, 400, "invalid_invite", "Invite code is invalid, used or expired");
    }
    const userId = crypto.randomUUID();
    const { options, challenge } = await passkeys.registrationOptions({ userId, userName: name });
    const challengeId = await store.saveChallenge({
      kind: "register",
      challenge,
      userId,
      inviteCodeHash: inviteHash,
      displayName: name,
      ttlSec: CHALLENGE_TTL_SEC,
    });
    return c.json({ challengeId, options });
  });

  app.post("/oauth/passkey/register/verify", async (c) => {
    const { body, req } = await readAuthRequest(c);
    if (!req) return expired(c);
    const ch = await store.takeChallenge(String(body.challengeId ?? ""), "register");
    if (!ch || !ch.userId || !ch.inviteCodeHash || !ch.displayName) return expired(c);
    const passkey = await passkeys.verifyRegistration({
      response: body.response,
      expectedChallenge: ch.challenge,
    });
    if (!passkey) return oauthError(c, 400, "passkey_rejected", "Passkey could not be verified");
    const ok = await store.registerUser({
      userId: ch.userId,
      displayName: ch.displayName,
      inviteCodeHash: ch.inviteCodeHash,
      passkey,
    });
    if (!ok) return oauthError(c, 400, "invalid_invite", "Invite code is invalid, used or expired");
    log("info", "auth.user_registered", { userId: ch.userId });
    return c.json({ redirect: await issueCode(req, ch.userId) });
  });

  // ---------- passkey sign-in ----------
  app.post("/oauth/passkey/login/options", async (c) => {
    const { req } = await readAuthRequest(c);
    if (!req) return expired(c);
    const { options, challenge } = await passkeys.authenticationOptions();
    const challengeId = await store.saveChallenge({
      kind: "login",
      challenge,
      userId: null,
      inviteCodeHash: null,
      displayName: null,
      ttlSec: CHALLENGE_TTL_SEC,
    });
    return c.json({ challengeId, options });
  });

  app.post("/oauth/passkey/login/verify", async (c) => {
    const { body, req } = await readAuthRequest(c);
    if (!req) return expired(c);
    const ch = await store.takeChallenge(String(body.challengeId ?? ""), "login");
    if (!ch) return expired(c);
    const credentialId = passkeys.credentialIdOf(body.response);
    const passkey = credentialId ? await store.getPasskey(credentialId) : null;
    if (!passkey) return oauthError(c, 400, "unknown_passkey", "This passkey is not registered");
    const verified = await passkeys.verifyAuthentication({
      response: body.response,
      expectedChallenge: ch.challenge,
      passkey,
    });
    if (!verified) return oauthError(c, 400, "passkey_rejected", "Passkey could not be verified");
    await store.touchPasskey(passkey.id, verified.newCounter);
    log("info", "auth.login", { userId: passkey.userId, clientId: req.cid });
    return c.json({ redirect: await issueCode(req, passkey.userId) });
  });

  // ---------- token endpoint ----------
  const readForm = async (c: AppContext): Promise<Record<string, string>> => {
    const type = c.req.header("content-type") ?? "";
    if (type.includes("application/json")) {
      const j = await c.req.json().catch(() => ({}));
      return Object.fromEntries(Object.entries(j).map(([k, v]) => [k, String(v)]));
    }
    const form = await c.req.parseBody().catch(() => ({}));
    return Object.fromEntries(
      Object.entries(form).filter(([, v]) => typeof v === "string") as [string, string][],
    );
  };

  const authenticateClient = async (
    c: AppContext,
    form: Record<string, string>,
  ): Promise<OAuthClient | null> => {
    let id = form.client_id;
    let secret = form.client_secret;
    const basic = c.req.header("authorization")?.match(/^Basic\s+(\S+)$/i);
    if (basic) {
      try {
        const [u, p] = atob(basic[1]).split(":");
        id = decodeURIComponent(u);
        secret = decodeURIComponent(p ?? "");
      } catch {
        return null;
      }
    }
    const client = id ? await store.getClient(id) : null;
    if (!client) return null;
    if (client.tokenEndpointAuthMethod === "none") return client;
    if (!secret || !client.clientSecretHash) return null;
    return timingSafeEqual(await sha256(secret), client.clientSecretHash) ? client : null;
  };

  const issueTokens = async (
    c: AppContext,
    t: {
      clientId: string;
      userId: string;
      scopes: string[];
      resource: string | null;
      familyId: string;
    },
  ) => {
    const now = deps.now().getTime();
    const access = randomToken("z2a");
    const refresh = randomToken("z2r");
    await store.saveToken(await sha256(access), {
      kind: "access",
      ...t,
      expiresAt: new Date(now + ACCESS_TOKEN_TTL_SEC * 1000),
    });
    await store.saveToken(await sha256(refresh), {
      kind: "refresh",
      ...t,
      expiresAt: new Date(now + REFRESH_TOKEN_TTL_SEC * 1000),
    });
    c.header("Cache-Control", "no-store");
    c.header("Pragma", "no-cache");
    return c.json({
      access_token: access,
      token_type: "Bearer",
      expires_in: ACCESS_TOKEN_TTL_SEC,
      refresh_token: refresh,
      scope: t.scopes.join(" "),
    });
  };

  app.post("/oauth/token", async (c) => {
    const form = await readForm(c);
    const client = await authenticateClient(c, form);
    if (!client) return oauthError(c, 401, "invalid_client");

    if (form.grant_type === "authorization_code") {
      if (!form.code || !form.code_verifier) {
        return oauthError(c, 400, "invalid_request", "code and code_verifier are required");
      }
      const code = await store.consumeCode(await sha256(form.code));
      if (!code || code.clientId !== client.clientId) return oauthError(c, 400, "invalid_grant");
      if (form.redirect_uri && form.redirect_uri !== code.redirectUri) {
        return oauthError(c, 400, "invalid_grant", "redirect_uri mismatch");
      }
      if (!(await verifyPkceS256(form.code_verifier, code.codeChallenge))) {
        return oauthError(c, 400, "invalid_grant", "PKCE verification failed");
      }
      const resource = code.resource ?? form.resource ?? null;
      if (resource && !validResource(resource)) return oauthError(c, 400, "invalid_target");
      return issueTokens(c, {
        clientId: client.clientId,
        userId: code.userId,
        scopes: code.scopes,
        resource,
        familyId: crypto.randomUUID(),
      });
    }

    if (form.grant_type === "refresh_token") {
      if (!form.refresh_token) return oauthError(c, 400, "invalid_request");
      const hash = await sha256(form.refresh_token);
      const rt = await store.findToken(hash);
      if (!rt || rt.kind !== "refresh" || rt.clientId !== client.clientId) {
        return oauthError(c, 400, "invalid_grant");
      }
      if (rt.revokedAt) {
        await store.revokeFamily(rt.familyId);
        log("warn", "oauth.refresh_reuse", { clientId: client.clientId, userId: rt.userId });
        return oauthError(c, 400, "invalid_grant", "Refresh token reuse detected");
      }
      if (rt.expiresAt.getTime() <= deps.now().getTime()) {
        return oauthError(c, 400, "invalid_grant");
      }
      let scopes = rt.scopes;
      if (form.scope) {
        const requested = form.scope.split(/\s+/).filter(Boolean);
        if (requested.some((s) => !rt.scopes.includes(s))) {
          return oauthError(c, 400, "invalid_scope");
        }
        scopes = requested;
      }
      await store.revokeToken(hash);
      return issueTokens(c, {
        clientId: client.clientId,
        userId: rt.userId,
        scopes,
        resource: rt.resource,
        familyId: rt.familyId,
      });
    }

    return oauthError(c, 400, "unsupported_grant_type");
  });

  // ---------- revocation (RFC 7009) ----------
  app.post("/oauth/revoke", async (c) => {
    const form = await readForm(c);
    const client = await authenticateClient(c, form);
    if (!client) return oauthError(c, 401, "invalid_client");
    if (form.token) {
      const hash = await sha256(form.token);
      const t = await store.findToken(hash);
      if (t && t.clientId === client.clientId) {
        if (t.kind === "refresh") await store.revokeFamily(t.familyId);
        else await store.revokeToken(hash);
      }
    }
    return c.body(null, 200);
  });

  return app;
}
