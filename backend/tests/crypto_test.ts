import { assert, assertEquals, assertFalse } from "@std/assert";
import {
  base64url,
  fromBase64url,
  normalizeInviteCode,
  sha256,
  signPayload,
  verifyPayload,
  verifyPkceS256,
} from "../src/auth/crypto.ts";

Deno.test("base64url round-trips", () => {
  const bytes = crypto.getRandomValues(new Uint8Array(33));
  assertEquals(fromBase64url(base64url(bytes)), bytes);
});

Deno.test("PKCE S256 matches RFC 7636 appendix B example", async () => {
  const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
  assertEquals(await sha256(verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
  assert(await verifyPkceS256(verifier, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"));
  assertFalse(await verifyPkceS256("short", "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"));
});

Deno.test("signed payloads verify, expire and reject tampering", async () => {
  const secret = "s".repeat(40);
  const token = await signPayload({ a: 1, exp: 100 }, secret);
  assertEquals((await verifyPayload<{ a: number; exp: number }>(token, secret, 50))?.a, 1);
  assertEquals(await verifyPayload(token, secret, 100), null);
  assertEquals(await verifyPayload(token, "t".repeat(40), 50), null);
  const [body, mac] = token.split(".");
  assertEquals(await verifyPayload(`${body}x.${mac}`, secret, 50), null);
});

Deno.test("invite codes are normalized", () => {
  assertEquals(normalizeInviteCode("  ab cd-12 "), "ABCD-12");
});
