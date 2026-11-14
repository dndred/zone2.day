// Small crypto helpers on top of WebCrypto (works in Deno, Workers, Node ≥ 20).

const enc = new TextEncoder();

export function base64url(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function fromBase64url(s: string): Uint8Array {
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4);
  const bin = atob(b64);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

/** Random opaque token with a readable prefix, e.g. "z2a_…" (32 random bytes). */
export function randomToken(prefix: string, bytes = 32): string {
  return `${prefix}_${base64url(crypto.getRandomValues(new Uint8Array(bytes)))}`;
}

/** SHA-256 → base64url. Used to store tokens, codes, secrets and invite codes. */
export async function sha256(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", enc.encode(input));
  return base64url(new Uint8Array(digest));
}

/** RFC 7636 S256 check. */
export async function verifyPkceS256(verifier: string, challenge: string): Promise<boolean> {
  if (!/^[A-Za-z0-9\-._~]{43,128}$/.test(verifier)) return false;
  return timingSafeEqual(await sha256(verifier), challenge);
}

export function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function hmacKey(secret: string): Promise<CryptoKey> {
  return await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
}

/** Signs a JSON payload: base64url(json).base64url(hmac). Payload must carry its own `exp`. */
export async function signPayload(payload: unknown, secret: string): Promise<string> {
  const body = base64url(enc.encode(JSON.stringify(payload)));
  const mac = await crypto.subtle.sign("HMAC", await hmacKey(secret), enc.encode(body));
  return `${body}.${base64url(new Uint8Array(mac))}`;
}

export async function verifyPayload<T extends { exp: number }>(
  token: string,
  secret: string,
  nowSec: number,
): Promise<T | null> {
  const [body, mac] = token.split(".");
  if (!body || !mac) return null;
  const expected = await crypto.subtle.sign("HMAC", await hmacKey(secret), enc.encode(body));
  if (!timingSafeEqual(base64url(new Uint8Array(expected)), mac)) return null;
  try {
    const payload = JSON.parse(new TextDecoder().decode(fromBase64url(body))) as T;
    return payload.exp > nowSec ? payload : null;
  } catch {
    return null;
  }
}

/** Invite codes are typed by hand: normalize before hashing. */
export function normalizeInviteCode(code: string): string {
  return code.trim().toUpperCase().replace(/\s+/g, "");
}
