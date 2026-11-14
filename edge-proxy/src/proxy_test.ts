import { assertEquals, assertExists } from "@std/assert";
import { buildUpstreamRequest, proxy } from "./proxy.ts";

const env = { ORIGIN: "https://ref.supabase.co/functions/v1/api/" };

Deno.test("maps path and query onto ORIGIN", () => {
  const up = buildUpstreamRequest(
    new Request("https://api.zone2.day/.well-known/oauth-authorization-server?x=1"),
    env,
  );
  assertEquals(
    up.url,
    "https://ref.supabase.co/functions/v1/api/.well-known/oauth-authorization-server?x=1",
  );
});

Deno.test("sets forwarding headers and keeps auth", () => {
  const up = buildUpstreamRequest(
    new Request("https://api.zone2.day/mcp", {
      headers: { authorization: "Bearer t", "x-request-id": "rid" },
    }),
    env,
  );
  assertEquals(up.headers.get("x-forwarded-host"), "api.zone2.day");
  assertEquals(up.headers.get("x-forwarded-proto"), "https");
  assertEquals(up.headers.get("authorization"), "Bearer t");
  assertEquals(up.headers.get("x-request-id"), "rid");
});

Deno.test("generates request id when missing", () => {
  const up = buildUpstreamRequest(new Request("https://api.zone2.day/health"), env);
  assertExists(up.headers.get("x-request-id"));
});

Deno.test("forwards POST body", async () => {
  let seen = "";
  const res = await proxy(
    new Request("https://api.zone2.day/oauth/token", { method: "POST", body: "a=1" }),
    env,
    async (r) => {
      seen = `${r.method} ${await r.text()}`;
      return new Response("ok");
    },
  );
  assertEquals(await res.text(), "ok");
  assertEquals(seen, "POST a=1");
});

Deno.test("returns 502 when upstream is unreachable", async () => {
  const res = await proxy(new Request("https://api.zone2.day/health"), env, () => {
    throw new Error("boom");
  });
  assertEquals(res.status, 502);
  assertEquals((await res.json()).error, "upstream_unreachable");
});
