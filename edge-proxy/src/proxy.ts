/**
 * Thin reverse proxy: https://api.zone2.day/<path> → ${ORIGIN}/<path>.
 * No business logic, no caching. Moving the backend = changing ORIGIN (docs/02-architecture.md §4).
 */
export interface ProxyEnv {
  /** Backend origin incl. base path, e.g. https://<ref>.supabase.co/functions/v1/api */
  ORIGIN: string;
}

type Fetcher = (input: Request) => Promise<Response>;

const HOP_BY_HOP = [
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
  "host",
];

export function buildUpstreamRequest(req: Request, env: ProxyEnv): Request {
  const incoming = new URL(req.url);
  const origin = env.ORIGIN.replace(/\/$/, "");
  const target = new URL(origin + incoming.pathname + incoming.search);

  const headers = new Headers(req.headers);
  for (const h of HOP_BY_HOP) headers.delete(h);
  headers.set("x-forwarded-host", incoming.host);
  headers.set("x-forwarded-proto", incoming.protocol.replace(":", ""));
  if (!headers.has("x-request-id")) headers.set("x-request-id", crypto.randomUUID());

  const hasBody = !["GET", "HEAD"].includes(req.method);
  return new Request(target, {
    method: req.method,
    headers,
    body: hasBody ? req.body : undefined,
    redirect: "manual",
    // @ts-ignore: required by fetch when streaming a request body (not in all TS lib typings)
    duplex: hasBody ? "half" : undefined,
  });
}

/**
 * Undo hosting-platform header rewrites (Supabase: text/html → text/plain, CSP → sandbox)
 * using the originals the backend put into x-zone2-*; drop upstream cookies (we use none,
 * and Supabase's bot cookies are scoped to supabase.co anyway).
 */
export function restoreHeaders(res: Response): Response {
  const type = res.headers.get("x-zone2-content-type");
  const hasCookies = res.headers.has("set-cookie");
  if (!type && !hasCookies) return res;
  const headers = new Headers(res.headers);
  headers.delete("set-cookie");
  if (type) {
    headers.set("content-type", type);
    const csp = res.headers.get("x-zone2-csp");
    if (csp) headers.set("content-security-policy", csp);
    else headers.delete("content-security-policy");
    headers.delete("x-zone2-content-type");
    headers.delete("x-zone2-csp");
  }
  return new Response(res.body, { status: res.status, statusText: res.statusText, headers });
}

export async function proxy(
  req: Request,
  env: ProxyEnv,
  fetcher: Fetcher = fetch,
): Promise<Response> {
  if (!env.ORIGIN) {
    return Response.json({ error: "proxy_misconfigured" }, { status: 500 });
  }
  try {
    return restoreHeaders(await fetcher(buildUpstreamRequest(req, env)));
  } catch (err) {
    return Response.json(
      { error: "upstream_unreachable", detail: err instanceof Error ? err.message : String(err) },
      { status: 502 },
    );
  }
}
