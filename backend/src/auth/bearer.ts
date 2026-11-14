import { sha256 } from "./crypto.ts";
import type { AuthStore } from "./store.ts";

export interface AuthContext {
  userId: string;
  clientId: string;
  scopes: string[];
  token: string;
  expiresAt: Date;
  resource: string | null;
}

export type BearerResult =
  | { ok: true; auth: AuthContext }
  | { ok: false; error: "missing" | "invalid" | "insufficient_scope" };

/** Validates an `Authorization: Bearer …` access token against the store. */
export async function verifyBearer(
  store: AuthStore,
  header: string | undefined,
  opts: { now: Date; scope: string; resource: string },
): Promise<BearerResult> {
  const match = header?.match(/^Bearer\s+(\S+)$/i);
  if (!match) return { ok: false, error: "missing" };
  const token = match[1];
  const stored = await store.findToken(await sha256(token));
  if (
    !stored || stored.kind !== "access" || stored.revokedAt ||
    stored.expiresAt.getTime() <= opts.now.getTime()
  ) {
    return { ok: false, error: "invalid" };
  }
  if (stored.resource && stored.resource !== opts.resource) return { ok: false, error: "invalid" };
  if (!stored.scopes.includes(opts.scope)) return { ok: false, error: "insufficient_scope" };
  return {
    ok: true,
    auth: {
      userId: stored.userId,
      clientId: stored.clientId,
      scopes: stored.scopes,
      token,
      expiresAt: stored.expiresAt,
      resource: stored.resource,
    },
  };
}
