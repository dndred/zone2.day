// Snapshot of the MCP contract (tool names, descriptions, input schemas).
// Any change shows up as a diff of schema/mcp-tools.json; accept it with `just mcp-snapshot-update`.
import { assertEquals } from "@std/assert";
import { mcpHarness } from "./helpers/mcp.ts";

const SNAPSHOT = new URL("../../schema/mcp-tools.json", import.meta.url);

Deno.test("MCP tool contract matches schema/mcp-tools.json", async () => {
  const h = await mcpHarness();
  try {
    const list = await h.rpc("tools/list");
    const tools = list.result.tools
      .map((t: Record<string, unknown>) => ({
        name: t.name,
        title: t.title,
        description: t.description,
        annotations: t.annotations,
        inputSchema: t.inputSchema,
      }))
      .sort((a: { name: string }, b: { name: string }) => a.name.localeCompare(b.name));
    const current = JSON.stringify({ tools }, null, 2) + "\n";
    if (Deno.env.get("UPDATE_MCP_SNAPSHOT") === "1") {
      await Deno.mkdir(new URL(".", SNAPSHOT), { recursive: true });
      await Deno.writeTextFile(SNAPSHOT, current);
      return;
    }
    let saved = "";
    try {
      saved = await Deno.readTextFile(SNAPSHOT);
    } catch {
      throw new Error("schema/mcp-tools.json missing — run `just mcp-snapshot-update`");
    }
    assertEquals(
      current,
      saved,
      "MCP contract changed — review and run `just mcp-snapshot-update`",
    );
  } finally {
    await h.drop();
  }
});
