// Supabase Edge Function entry point.
// Supabase routes https://<ref>.supabase.co/functions/v1/api/* to the function with the
// path still prefixed by the function name ("/api/..."). We strip the prefix and hand the
// request to the app unchanged, so the app's own 404/error handlers apply everywhere.
import { createApp } from "../app.ts";
import { loadConfig } from "../config.ts";

export const FUNCTION_NAME = "api";

export function stripFunctionPrefix(req: Request, prefix = `/${FUNCTION_NAME}`): Request {
  const url = new URL(req.url);
  if (url.pathname !== prefix && !url.pathname.startsWith(`${prefix}/`)) return req;
  url.pathname = url.pathname.slice(prefix.length) || "/";
  return new Request(url, req);
}

export function createSupabaseHandler(): (req: Request) => Response | Promise<Response> {
  const app = createApp(loadConfig());
  return (req) => app.fetch(stripFunctionPrefix(req));
}
