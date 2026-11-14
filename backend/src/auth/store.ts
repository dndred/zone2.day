import type { Sql } from "../db/client.ts";

export type TokenEndpointAuthMethod = "none" | "client_secret_post" | "client_secret_basic";

export interface OAuthClient {
  clientId: string;
  clientSecretHash: string | null;
  clientName: string | null;
  redirectUris: string[];
  tokenEndpointAuthMethod: TokenEndpointAuthMethod;
}

export interface StoredPasskey {
  id: string;
  userId: string;
  publicKey: Uint8Array;
  counter: number;
  transports: string[];
}

export interface NewPasskey {
  id: string;
  publicKey: Uint8Array;
  counter: number;
  transports: string[];
  deviceType?: string;
  backedUp?: boolean;
}

export interface Challenge {
  id: string;
  kind: "register" | "login";
  challenge: string;
  userId: string | null;
  inviteCodeHash: string | null;
  displayName: string | null;
}

export interface AuthCode {
  clientId: string;
  userId: string;
  redirectUri: string;
  codeChallenge: string;
  scopes: string[];
  resource: string | null;
}

export interface StoredToken {
  kind: "access" | "refresh";
  clientId: string;
  userId: string;
  scopes: string[];
  resource: string | null;
  familyId: string;
  expiresAt: Date;
  revokedAt: Date | null;
}

/** All SQL for accounts, passkeys and OAuth. Everything is keyed by hashes, never raw secrets. */
export class AuthStore {
  constructor(private readonly sql: Sql) {}

  // ---- clients ----

  async createClient(c: OAuthClient & { metadata?: Record<string, unknown> }): Promise<void> {
    await this.sql`
      insert into zone2.oauth_clients
        (client_id, client_secret_hash, client_name, redirect_uris, token_endpoint_auth_method, metadata)
      values (${c.clientId}, ${c.clientSecretHash}, ${c.clientName}, ${c.redirectUris},
              ${c.tokenEndpointAuthMethod}, ${this.sql.json((c.metadata ?? {}) as never)})`;
  }

  async getClient(clientId: string): Promise<OAuthClient | null> {
    const [row] = await this.sql`
      select client_id, client_secret_hash, client_name, redirect_uris, token_endpoint_auth_method
      from zone2.oauth_clients where client_id = ${clientId}`;
    if (!row) return null;
    return {
      clientId: row.client_id,
      clientSecretHash: row.client_secret_hash,
      clientName: row.client_name,
      redirectUris: row.redirect_uris,
      tokenEndpointAuthMethod: row.token_endpoint_auth_method,
    };
  }

  // ---- users, invites, passkeys ----

  async isInviteUsable(codeHash: string): Promise<boolean> {
    const [row] = await this.sql`
      select 1 from zone2.invites
      where code_hash = ${codeHash} and used_at is null and expires_at > now()`;
    return Boolean(row);
  }

  /** Atomically consumes the invite, creates the user and stores the passkey. */
  async registerUser(input: {
    userId: string;
    displayName: string;
    inviteCodeHash: string;
    passkey: NewPasskey;
  }): Promise<boolean> {
    return await this.sql.begin(async (tx) => {
      const used = await tx`
        update zone2.invites set used_at = now(), used_by = null
        where code_hash = ${input.inviteCodeHash} and used_at is null and expires_at > now()
        returning code_hash`;
      if (used.length === 0) return false;
      await tx`insert into zone2.users (id, display_name) values (${input.userId}, ${input.displayName})`;
      await tx`update zone2.invites set used_by = ${input.userId} where code_hash = ${input.inviteCodeHash}`;
      const p = input.passkey;
      await tx`
        insert into zone2.passkeys (id, user_id, public_key, counter, transports, device_type, backed_up)
        values (${p.id}, ${input.userId}, ${p.publicKey}, ${p.counter}, ${p.transports},
                ${p.deviceType ?? null}, ${p.backedUp ?? null})`;
      return true;
    }) as boolean;
  }

  async getPasskey(id: string): Promise<StoredPasskey | null> {
    const [row] = await this.sql`
      select id, user_id, public_key, counter, transports from zone2.passkeys where id = ${id}`;
    if (!row) return null;
    return {
      id: row.id,
      userId: row.user_id,
      publicKey: new Uint8Array(row.public_key),
      counter: Number(row.counter),
      transports: row.transports,
    };
  }

  async touchPasskey(id: string, counter: number): Promise<void> {
    await this.sql`
      update zone2.passkeys set counter = ${counter}, last_used_at = now() where id = ${id}`;
  }

  // ---- WebAuthn challenges ----

  async saveChallenge(c: Omit<Challenge, "id"> & { ttlSec: number }): Promise<string> {
    const [row] = await this.sql`
      insert into zone2.webauthn_challenges (kind, challenge, user_id, invite_code_hash, display_name, expires_at)
      values (${c.kind}, ${c.challenge}, ${c.userId}, ${c.inviteCodeHash}, ${c.displayName},
              now() + make_interval(secs => ${c.ttlSec}))
      returning id`;
    return row.id;
  }

  /** One-shot: deletes and returns the challenge if it exists, matches kind and is not expired. */
  async takeChallenge(id: string, kind: Challenge["kind"]): Promise<Challenge | null> {
    if (!isUuid(id)) return null;
    const [row] = await this.sql`
      delete from zone2.webauthn_challenges
      where id = ${id} and kind = ${kind} and expires_at > now()
      returning id, kind, challenge, user_id, invite_code_hash, display_name`;
    if (!row) return null;
    return {
      id: row.id,
      kind: row.kind,
      challenge: row.challenge,
      userId: row.user_id,
      inviteCodeHash: row.invite_code_hash,
      displayName: row.display_name,
    };
  }

  // ---- authorization codes ----

  async saveCode(codeHash: string, code: AuthCode, ttlSec: number): Promise<void> {
    await this.sql`
      insert into zone2.oauth_codes
        (code_hash, client_id, user_id, redirect_uri, code_challenge, scopes, resource, expires_at)
      values (${codeHash}, ${code.clientId}, ${code.userId}, ${code.redirectUri}, ${code.codeChallenge},
              ${code.scopes}, ${code.resource}, now() + make_interval(secs => ${ttlSec}))`;
  }

  /** One-shot: marks the code used and returns it if it was unused and not expired. */
  async consumeCode(codeHash: string): Promise<AuthCode | null> {
    const [row] = await this.sql`
      update zone2.oauth_codes set used_at = now()
      where code_hash = ${codeHash} and used_at is null and expires_at > now()
      returning client_id, user_id, redirect_uri, code_challenge, scopes, resource`;
    if (!row) return null;
    return {
      clientId: row.client_id,
      userId: row.user_id,
      redirectUri: row.redirect_uri,
      codeChallenge: row.code_challenge,
      scopes: row.scopes,
      resource: row.resource,
    };
  }

  // ---- tokens ----

  async saveToken(tokenHash: string, t: Omit<StoredToken, "revokedAt">): Promise<void> {
    await this.sql`
      insert into zone2.oauth_tokens
        (token_hash, kind, client_id, user_id, scopes, resource, family_id, expires_at)
      values (${tokenHash}, ${t.kind}, ${t.clientId}, ${t.userId}, ${t.scopes}, ${t.resource},
              ${t.familyId}, ${t.expiresAt})`;
  }

  async findToken(tokenHash: string): Promise<StoredToken | null> {
    const [row] = await this.sql`
      select kind, client_id, user_id, scopes, resource, family_id, expires_at, revoked_at
      from zone2.oauth_tokens where token_hash = ${tokenHash}`;
    if (!row) return null;
    return {
      kind: row.kind,
      clientId: row.client_id,
      userId: row.user_id,
      scopes: row.scopes,
      resource: row.resource,
      familyId: row.family_id,
      expiresAt: new Date(row.expires_at),
      revokedAt: row.revoked_at ? new Date(row.revoked_at) : null,
    };
  }

  /** Revokes a single token; returns true if it was active. */
  async revokeToken(tokenHash: string): Promise<boolean> {
    const rows = await this.sql`
      update zone2.oauth_tokens set revoked_at = now()
      where token_hash = ${tokenHash} and revoked_at is null returning 1`;
    return rows.length > 0;
  }

  async revokeFamily(familyId: string): Promise<void> {
    await this.sql`
      update zone2.oauth_tokens set revoked_at = now()
      where family_id = ${familyId} and revoked_at is null`;
  }

  async getUserName(userId: string): Promise<string | null> {
    const [row] = await this.sql`select display_name from zone2.users where id = ${userId}`;
    return row?.display_name ?? null;
  }
}

function isUuid(s: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s);
}
