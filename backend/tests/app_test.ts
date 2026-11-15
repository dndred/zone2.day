import { assert, assertEquals, assertMatch } from "@std/assert";
import { createApp } from "../src/app.ts";
import { type Config, loadConfig } from "../src/config.ts";

const testConfig: Config = {
  env: "test",
  version: "test-sha",
  publicBaseUrl: "http://localhost:8787",
  rpId: "localhost",
  secretKey: "x".repeat(40),
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
    ({
      ZONE2_ENV: "staging",
      ZONE2_PUBLIC_BASE_URL: "https://api-staging.zone2.day/",
      ZONE2_RP_ID: "zone2.day",
      ZONE2_SECRET_KEY: "k".repeat(40),
    })[name]
  );
  assertEquals(cfg.env, "staging");
  assertEquals(cfg.version, "dev");
  assertEquals(cfg.publicBaseUrl, "https://api-staging.zone2.day");
  assertEquals(cfg.rpId, "zone2.day");
});

Deno.test("loadConfig requires a real secret outside local/test", () => {
  let threw = false;
  try {
    loadConfig((name) => (name === "ZONE2_ENV" ? "staging" : undefined));
  } catch {
    threw = true;
  }
  assert(threw);
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

Deno.test("GET /icon.png and /favicon.ico serve the mark of the environment", async () => {
  const png = [0x89, 0x50, 0x4e, 0x47];
  const staging = await createApp(testConfig).request("/icon.png");
  assertEquals(staging.status, 200);
  assertEquals(staging.headers.get("content-type"), "image/png");
  const stagingBytes = new Uint8Array(await staging.arrayBuffer());
  assertEquals([...stagingBytes.slice(0, 4)], png);
  assert(stagingBytes.length <= 10_240); // ChatGPT's limit for connector icons
  const prod = await createApp({ ...testConfig, env: "prod" }).request("/favicon.ico");
  const prodBytes = new Uint8Array(await prod.arrayBuffer());
  assertEquals([...prodBytes.slice(0, 4)], png);
  assert(prodBytes.length !== stagingBytes.length, "prod and staging icons differ");
});
