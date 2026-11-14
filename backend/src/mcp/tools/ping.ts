import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { McpContext } from "../server.ts";

export function registerPing(server: McpServer, ctx: McpContext): void {
  server.registerTool(
    "ping",
    {
      title: "Ping zone2.day",
      description:
        "Checks the connection to zone2.day. Returns server time, environment, build version and the signed-in athlete. " +
        "Use when the athlete asks whether the connection works or when other tools fail unexpectedly. No side effects.",
      annotations: { readOnlyHint: true, idempotentHint: true, openWorldHint: false },
    },
    async () => {
      const payload = {
        pong: true,
        server_time: ctx.now().toISOString(),
        env: ctx.config.env,
        version: ctx.config.version,
        athlete: { id: ctx.auth.userId, name: await ctx.store.getUserName(ctx.auth.userId) },
        client_id: ctx.auth.clientId,
      };
      return { content: [{ type: "text", text: JSON.stringify(payload, null, 2) }] };
    },
  );
}
