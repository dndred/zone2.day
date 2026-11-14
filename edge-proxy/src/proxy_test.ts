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

Deno.test("restores HTML content type and CSP rewritten by the platform, drops cookies", async () => {
  const res = await proxy(
    new Request("https://api.zone2.day/oauth/authorize"),
    env,
    () =>
      Promise.resolve(
        new Response("<html></html>", {
          headers: {
            "content-type": "text/plain",
            "content-security-policy": "default-src 'none'; sandbox",
            "x-zone2-content-type": "text/html; charset=UTF-8",
            "x-zone2-csp": "default-src 'none'; script-src 'unsafe-inline'",
            "set-cookie": "__cf_bm=x; Domain=supabase.co",
          },
        }),
      ),
  );
  assertEquals(res.headers.get("content-type"), "text/html; charset=UTF-8");
  assertEquals(
    res.headers.get("content-security-policy"),
    "default-src 'none'; script-src 'unsafe-inline'",
  );
  assertEquals(res.headers.get("set-cookie"), null);
  assertEquals(res.headers.get("x-zone2-content-type"), null);
  assertEquals(await res.text(), "<html></html>");
});

Deno.test("leaves JSON responses untouched", async () => {
  const upstream = Response.json({ ok: true });
  const res = await proxy(
    new Request("https://api.zone2.day/health"),
    env,
    () => Promise.resolve(upstream),
  );
  assertEquals(res, upstream);
});

Deno.test("returns 502 when upstream is unreachable", async () => {
  const res = await proxy(new Request("https://api.zone2.day/health"), env, () => {
    throw new Error("boom");
  });
  assertEquals(res.status, 502);
  assertEquals((await res.json()).error, "upstream_unreachable");
});
