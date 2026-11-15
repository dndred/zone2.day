// MCP endpoint: Streamable HTTP, stateless (a fresh server + transport per request).
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js";
import type { AuthContext } from "../auth/bearer.ts";
import type { AuthStore } from "../auth/store.ts";
import type { Config } from "../config.ts";
import type { ActivityStore } from "../db/activities.ts";
import type { DeliveryStore } from "../db/deliveries.ts";
import type { StrengthStore } from "../db/strength.ts";
import type { UploadStore } from "../db/uploads.ts";
import type { DocumentStore } from "../db/documents.ts";
import type { BlobStore } from "../ports/blob.ts";
import { registerActivityTools } from "./tools/activities.ts";
import { registerActivityInputTools } from "./tools/activity_input.ts";
import { registerContextTool } from "./tools/context.ts";
import { registerDeliveryTools } from "./tools/delivery.ts";
import { registerPing } from "./tools/ping.ts";
import { registerPlanTools } from "./tools/plan.ts";
import { registerStrengthTools } from "./tools/strength.ts";
import { registerRecordTools } from "./tools/records.ts";

export interface McpContext {
  config: Config;
  auth: AuthContext;
  store: AuthStore;
  docs: DocumentStore;
  activities: ActivityStore;
  deliveries: DeliveryStore;
  strength: StrengthStore;
  uploads: UploadStore;
  blobs: BlobStore;
  now: () => Date;
}

const INSTRUCTIONS = `zone2.day is the athlete's personal training system (run → triathlon).
You act as their coach: plans you write here reach their phone and Apple Watch automatically.
Human-readable fields you write (titles, goals, notes) must be in the athlete's language.
Start every conversation with get_context. Every write is logged with your \`why\` and can be undone with revert_change.
Completed workouts (Apple Health, FIT files, manual): list_activities / get_activity / get_activity_streams. Add a FIT (e.g. MyWhoosh) via create_upload_link → import_activity_file; a workout without a file via create_activity. Health metrics are not connected yet.
Gym: the athlete logs sets in the app; read get_strength_log, and get_exercise_history before choosing weights.`;

export function buildMcpServer(ctx: McpContext): McpServer {
  const server = new McpServer(
    { name: "zone2.day", version: ctx.config.version },
    { instructions: INSTRUCTIONS },
  );
  registerContextTool(server, ctx);
  registerPlanTools(server, ctx);
  registerRecordTools(server, ctx);
  registerActivityTools(server, ctx);
  registerActivityInputTools(server, ctx);
  registerDeliveryTools(server, ctx);
  registerStrengthTools(server, ctx);
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
