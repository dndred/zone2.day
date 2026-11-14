// Supabase Edge Function entry point.
// Supabase routes https://<ref>.supabase.co/functions/v1/api/* to the function with the
// path still prefixed by the function name ("/api/..."). We strip the prefix and hand the
// request to the app unchanged, so the app's own 404/error handlers apply everywhere.
import { createApp } from "../app.ts";
import { loadConfig } from "../config.ts";
import { createDeps } from "../deps.ts";

export const FUNCTION_NAME = "api";

export function stripFunctionPrefix(req: Request, prefix = `/${FUNCTION_NAME}`): Request {
  const url = new URL(req.url);
  if (url.pathname !== prefix && !url.pathname.startsWith(`${prefix}/`)) return req;
  url.pathname = url.pathname.slice(prefix.length) || "/";
  return new Request(url, req);
}

/** `version` is baked into the bundle at deploy time, so /health reports the code that is live. */
export function createSupabaseHandler(
  opts: { version?: string } = {},
): (req: Request) => Response | Promise<Response> {
  const loaded = loadConfig();
  const config = opts.version && opts.version !== "dev"
    ? { ...loaded, version: opts.version }
    : loaded;
  const app = createApp(config, createDeps(config));
  return (req) => app.fetch(stripFunctionPrefix(req));
}
