// Request log for /mcp: JSON-RPC method, tool name, protocol, and the transport's error text on 4xx.
import { assert, assertEquals } from "@std/assert";
import { mcpLogInfo } from "../src/app.ts";
import { mcpHarness } from "./helpers/mcp.ts";

Deno.test("mcpLogInfo: method, tool, protocol; no arguments", () => {
  const h = new Headers({ "mcp-protocol-version": "2025-06-18", "mcp-session-id": "s" });
  const info = mcpLogInfo(
    h,
    JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: "get_plan", arguments: { secret: "x" } },
    }),
  );
  assertEquals(info, {
    protocol: "2025-06-18",
    session: true,
    rpc: "tools/call",
    tool: "get_plan",
  });
  assertEquals(
    mcpLogInfo(
      new Headers(),
      JSON.stringify({ method: "initialize", params: { protocolVersion: "2025-11-25" } }),
    ),
    { rpc: "initialize", protocol: "-→2025-11-25" },
  );
  assertEquals(mcpLogInfo(new Headers(), '[{"id":1,"result":{}}]'), { rpc: "response" });
  assertEquals(mcpLogInfo(new Headers(), "{"), { rpc: "invalid-json" });
});

Deno.test("/mcp request log: body still reaches the transport; 400 carries the error", async () => {
  const h = await mcpHarness();
  const lines: string[] = [];
  const orig = console.log;
  console.log = (line: string) => lines.push(line);
  try {
    const ok = await h.call("get_context", {});
    assert(!ok.isError);
    const bad = await h.app.request("/mcp", {
      method: "POST",
      headers: {
        authorization: `Bearer ${h.token}`,
        "content-type": "application/json",
        accept: "application/json, text/event-stream",
        "mcp-protocol-version": "2099-01-01",
      },
      body: JSON.stringify({ jsonrpc: "2.0", id: 7, method: "tools/list" }),
    });
    assertEquals(bad.status, 400);
  } finally {
    console.log = orig;
    await h.drop();
  }
  const reqs = lines.map((l) => JSON.parse(l)).filter((l) =>
    l.msg === "request" && l.path === "/mcp"
  );
  const call = reqs.find((l) => l.tool === "get_context");
  assertEquals(call?.rpc, "tools/call");
  assertEquals(call?.status, 200);
  const err = reqs.find((l) => l.status === 400);
  assertEquals(err?.rpc, "tools/list");
  assertEquals(err?.protocol, "2099-01-01");
  assert(String(err?.error).includes("Unsupported protocol version"), err?.error);
});
