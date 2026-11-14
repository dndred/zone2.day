// Shared plumbing for MCP tools: uniform success/error envelopes, athlete time, change metadata.
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { type ChangeMeta, ConflictError, NotFoundError } from "../db/documents.ts";
import { DEFAULT_PROFILE, Profile } from "../domain/entities.ts";
import { type AthleteNow, athleteNow } from "../domain/time.ts";
import { log } from "../log.ts";
import type { McpContext } from "./server.ts";

export class ToolError extends Error {
  constructor(readonly code: string, message: string, readonly hint?: string) {
    super(message);
  }
}

export interface ToolEnv {
  ctx: McpContext;
  userId: string;
  profile(): Promise<Profile>;
  now(): Promise<AthleteNow>;
  meta(tool: string, why?: string | null): Promise<ChangeMeta>;
}

function makeEnv(ctx: McpContext): ToolEnv {
  let profile: Promise<Profile> | null = null;
  let actor: Promise<string> | null = null;
  const env: ToolEnv = {
    ctx,
    userId: ctx.auth.userId,
    profile() {
      profile ??= ctx.docs.get(ctx.auth.userId, "profile", "profile").then((d) =>
        d ? Profile.parse(d.data) : DEFAULT_PROFILE
      );
      return profile;
    },
    async now() {
      return athleteNow(await env.profile(), ctx.now());
    },
    async meta(tool, why) {
      actor ??= ctx.store.getClient(ctx.auth.clientId).then((c) =>
        `ai:${c?.clientName ?? ctx.auth.clientId}`
      );
      return { actor: await actor, tool, why: why ?? null };
    },
  };
  return env;
}

export interface ToolSpec<S extends z.ZodRawShape> {
  title: string;
  description: string;
  input: S;
  readOnly?: boolean;
  destructive?: boolean;
}

type Payload = Record<string, unknown>;

/** Registers a tool whose result is `{ now, ...payload }` as compact JSON text. */
export function defineTool<S extends z.ZodRawShape>(
  server: McpServer,
  ctx: McpContext,
  name: string,
  spec: ToolSpec<S>,
  handler: (args: z.infer<z.ZodObject<S>>, env: ToolEnv) => Promise<Payload>,
): void {
  server.registerTool(
    name,
    {
      title: spec.title,
      description: spec.description,
      inputSchema: spec.input,
      annotations: {
        readOnlyHint: spec.readOnly ?? false,
        destructiveHint: spec.destructive ?? false,
        openWorldHint: false,
      },
    },
    // deno-lint-ignore no-explicit-any
    (async (args: any) => {
      const env = makeEnv(ctx);
      try {
        const payload = await handler(args, env);
        return text({ now: await env.now(), ...payload });
      } catch (err) {
        return errorResult(err, name, ctx.auth.userId);
      }
      // deno-lint-ignore no-explicit-any
    }) as any,
  );
}

function text(payload: unknown) {
  return { content: [{ type: "text" as const, text: JSON.stringify(payload) }] };
}

function errorResult(err: unknown, tool: string, userId: string) {
  let body: Payload;
  if (err instanceof ToolError) {
    body = { error: err.code, message: err.message, ...(err.hint ? { hint: err.hint } : {}) };
  } else if (err instanceof z.ZodError) {
    body = {
      error: "validation",
      issues: err.issues.slice(0, 10).map((i) => ({ path: i.path.join("."), message: i.message })),
      hint: "Fix the listed fields and call again; nothing was saved.",
    };
  } else if (err instanceof NotFoundError) {
    body = { error: "not_found", message: err.message };
  } else if (err instanceof ConflictError) {
    body = { error: "conflict", message: err.message };
  } else {
    log("error", "mcp.tool_failed", { tool, userId, error: String(err) });
    body = { error: "internal", message: "Unexpected server error; it was logged." };
  }
  return { ...text(body), isError: true };
}

/** `why` is required on plan mutations: it is shown on the workout card and read by later chats. */
export const Why = z.string().min(3).max(200).describe(
  "Why this change, in the athlete's language, as you'd say it aloud (≤200). Shown on the workout card.",
);
