import type { Context } from "@hono/hono";
import type { AuthContext } from "./auth/bearer.ts";

export type AppEnv = { Variables: { requestId: string; auth?: AuthContext } };
export type AppContext = Context<AppEnv>;
