// MCP endpoint, stateless: a fresh server per request. createMcpHandler serves the 2026-07-28
// revision (server/discover, per-request envelope) and falls back to 2025-era stateless
// Streamable HTTP for older clients — one tool set behind both.
import {
  createMcpHandler,
  isLegacyRequest,
  McpServer,
  WebStandardStreamableHTTPServerTransport,
} from "@modelcontextprotocol/server";
import type { AuthContext } from "../auth/bearer.ts";
import type { AuthStore } from "../auth/store.ts";
import type { Config } from "../config.ts";
import type { ActivityStore } from "../db/activities.ts";
import type { DeliveryStore } from "../db/deliveries.ts";
import type { StrengthStore } from "../db/strength.ts";
import type { UploadStore } from "../db/uploads.ts";
import type { DailyMetricsStore } from "../db/daily_metrics.ts";
import type { DocumentStore } from "../db/documents.ts";
import type { BlobStore } from "../ports/blob.ts";
import { mcpIcons } from "../icon.ts";
import { registerActivityTools } from "./tools/activities.ts";
import { registerActivityInputTools } from "./tools/activity_input.ts";
import { registerAnalyticsTools } from "./tools/analytics.ts";
import { registerContextTool } from "./tools/context.ts";
import { registerDeliveryTools } from "./tools/delivery.ts";
import { registerHealthTools } from "./tools/health.ts";
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
  metrics: DailyMetricsStore;
  blobs: BlobStore;
  now: () => Date;
}

const INSTRUCTIONS = `zone2.day is the athlete's personal training system (run → triathlon).
You act as their coach: plans you write here reach their phone and Apple Watch automatically.
Human-readable fields you write (titles, goals, notes) must be in the athlete's language. The app renders every text field except titles as Markdown (goal, notes, coachNotes, athleteNotes, week header/review, journal, event notes, notebook): use short paragraphs and bullet lists, **bold** for key numbers, headings only in long texts; no tables, HTML or code blocks.
Start every conversation with get_context. Every write is logged with your \`why\` and can be undone with revert_change.
Completed workouts (Apple Health, FIT files, manual): list_activities / get_activity / get_activity_streams. Add a FIT (e.g. MyWhoosh) via create_upload_link → import_activity_file; a workout without a file via create_activity. Load, time in zones and aerobic efficiency (pace/power at the same HR): get_load / get_zone_distribution / get_efficiency_trend — read them before planning a week. Recovery (resting HR, HRV, sleep, wrist temperature): get_daily_metrics; get_context shows the last 3 days.
Gym: the athlete logs sets in the app; read get_strength_log, and get_exercise_history before choosing weights.`;

export function buildMcpServer(ctx: McpContext): McpServer {
  const server = new McpServer(
    {
      name: "zone2.day",
      title: ctx.config.env === "prod" ? "zone2.day" : `zone2.day (${ctx.config.env})`,
      version: ctx.config.version,
      description:
        "Personal training system with an AI coach: plan, Apple Watch delivery, workouts, recovery.",
      icons: mcpIcons(ctx.config.publicBaseUrl),
    },
    { instructions: INSTRUCTIONS },
  );
  registerContextTool(server, ctx);
  registerPlanTools(server, ctx);
  registerRecordTools(server, ctx);
  registerActivityTools(server, ctx);
  registerActivityInputTools(server, ctx);
  registerAnalyticsTools(server, ctx);
  registerHealthTools(server, ctx);
  registerDeliveryTools(server, ctx);
  registerStrengthTools(server, ctx);
  registerPing(server, ctx);
  return server;
}

export async function handleMcpRequest(req: Request, ctx: McpContext): Promise<Response> {
  const authInfo = {
    token: ctx.auth.token,
    clientId: ctx.auth.clientId,
    scopes: ctx.auth.scopes,
    expiresAt: Math.floor(ctx.auth.expiresAt.getTime() / 1000),
    extra: { userId: ctx.auth.userId },
  };
  // 2025-era clients: stateless Streamable HTTP with plain JSON responses (no SSE), as before.
  if (await isLegacyRequest(req.clone())) {
    const server = buildMcpServer(ctx);
    const transport = new WebStandardStreamableHTTPServerTransport({
      sessionIdGenerator: undefined,
      enableJsonResponse: true,
    });
    await server.connect(transport);
    return await transport.handleRequest(req, { authInfo });
  }
  // 2026-07-28: server/discover + per-request envelope.
  const handler = createMcpHandler(() => buildMcpServer(ctx), {
    legacy: "reject",
    responseMode: "auto",
  });
  return await handler.fetch(req, { authInfo });
}
