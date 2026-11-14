import { assert, assertEquals, assertMatch } from "@std/assert";
import { createApp } from "../src/app.ts";
import { type Config, loadConfig } from "../src/config.ts";

const testConfig: Config = {
  env: "test",
  version: "test-sha",
  publicBaseUrl: "http://localhost:8787",
};

Deno.test("GET /health returns ok with env and version", async () => {
  const app = createApp(testConfig);
  const res = await app.request("/health");
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.ok, true);
  assertEquals(body.env, "test");
  assertEquals(body.version, "test-sha");
  assertMatch(res.headers.get("x-request-id") ?? "", /^[0-9a-f-]{36}$/);
});

Deno.test("request id is propagated from the client", async () => {
  const app = createApp(testConfig);
  const res = await app.request("/health", { headers: { "x-request-id": "abc-123" } });
  assertEquals(res.headers.get("x-request-id"), "abc-123");
});

Deno.test("unknown route returns JSON 404", async () => {
  const app = createApp(testConfig);
  const res = await app.request("/nope");
  assertEquals(res.status, 404);
  assertEquals(await res.json(), { error: "not_found", path: "/nope" });
});

Deno.test("loadConfig applies defaults and strips trailing slash", () => {
  const cfg = loadConfig((name) =>
    ({ ZONE2_ENV: "staging", ZONE2_PUBLIC_BASE_URL: "https://api-staging.zone2.day/" })[name]
  );
  assertEquals(cfg.env, "staging");
  assertEquals(cfg.version, "dev");
  assertEquals(cfg.publicBaseUrl, "https://api-staging.zone2.day");
});

Deno.test("loadConfig rejects unknown env", () => {
  let threw = false;
  try {
    loadConfig((name) => (name === "ZONE2_ENV" ? "production" : undefined));
  } catch {
    threw = true;
  }
  assert(threw);
});
