import { assertEquals } from "@std/assert";
import { createSupabaseHandler, stripFunctionPrefix } from "../src/entry/supabase.ts";

Deno.env.set("ZONE2_ENV", "test");

Deno.test("supabase entry serves the app under /api", async () => {
  const handler = createSupabaseHandler();
  const res = await handler(new Request("http://localhost/api/health"));
  assertEquals(res.status, 200);
  assertEquals((await res.json()).service, "zone2-api");
});

Deno.test("unknown paths get the app's JSON 404, not a router default", async () => {
  const handler = createSupabaseHandler();
  const res = await handler(new Request("http://localhost/api/nope"));
  assertEquals(res.status, 404);
  assertEquals(await res.json(), { error: "not_found", path: "/nope" });

  const post = await handler(
    new Request("http://localhost/api/oauth/token", { method: "POST", body: "a=1" }),
  );
  assertEquals(post.status, 404);
  assertEquals((await post.json()).error, "not_found");
});

Deno.test("stripFunctionPrefix keeps method, body, query", async () => {
  const req = stripFunctionPrefix(
    new Request("http://localhost/api/x/y?q=1", { method: "POST", body: "hello" }),
  );
  assertEquals(new URL(req.url).pathname, "/x/y");
  assertEquals(new URL(req.url).search, "?q=1");
  assertEquals(req.method, "POST");
  assertEquals(await req.text(), "hello");
});

Deno.test("stripFunctionPrefix maps bare prefix to / and ignores look-alikes", () => {
  assertEquals(new URL(stripFunctionPrefix(new Request("http://l/api")).url).pathname, "/");
  assertEquals(new URL(stripFunctionPrefix(new Request("http://l/apix")).url).pathname, "/apix");
});
