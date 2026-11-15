import type { Context } from "@hono/hono";
import type { AuthContext } from "./auth/bearer.ts";

/** What an /mcp request was, for the request log: JSON-RPC method(s), tool, protocol, error. */
export interface McpLogInfo {
  rpc?: string;
  tool?: string;
  protocol?: string;
  session?: boolean;
  error?: string;
}

export type AppEnv = {
  Variables: { requestId: string; auth?: AuthContext; mcp?: McpLogInfo };
};
export type AppContext = Context<AppEnv>;
