// MCP endpoint: Streamable HTTP, stateless (a fresh server + transport per request).
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js";
import type { AuthContext } from "../auth/bearer.ts";
import type { AuthStore } from "../auth/store.ts";
import type { Config } from "../config.ts";
import { registerPing } from "./tools/ping.ts";

export interface McpContext {
  config: Config;
  auth: AuthContext;
  store: AuthStore;
  now: () => Date;
}

const INSTRUCTIONS = `zone2.day is the athlete's personal training system (run → triathlon).
You act as their coach: plans you write here reach their phone and Apple Watch automatically.
Human-readable fields you write (titles, goals, notes) must be in the athlete's language.
More tools are being added; currently available: ping.`;

export function buildMcpServer(ctx: McpContext): McpServer {
  const server = new McpServer(
    { name: "zone2.day", version: ctx.config.version },
    { instructions: INSTRUCTIONS },
  );
  registerPing(server, ctx);
  return server;
}

export async function handleMcpRequest(req: Request, ctx: McpContext): Promise<Response> {
  const server = buildMcpServer(ctx);
  const transport = new WebStandardStreamableHTTPServerTransport({
    sessionIdGenerator: undefined,
    enableJsonResponse: true,
  });
  await server.connect(transport);
  return await transport.handleRequest(req, {
    authInfo: {
      token: ctx.auth.token,
      clientId: ctx.auth.clientId,
      scopes: ctx.auth.scopes,
      expiresAt: Math.floor(ctx.auth.expiresAt.getTime() / 1000),
      extra: { userId: ctx.auth.userId },
    },
  });
}
