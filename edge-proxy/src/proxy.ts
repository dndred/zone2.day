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

export async function proxy(
  req: Request,
  env: ProxyEnv,
  fetcher: Fetcher = fetch,
): Promise<Response> {
  if (!env.ORIGIN) {
    return Response.json({ error: "proxy_misconfigured" }, { status: 500 });
  }
  try {
    return await fetcher(buildUpstreamRequest(req, env));
  } catch (err) {
    return Response.json(
      { error: "upstream_unreachable", detail: err instanceof Error ? err.message : String(err) },
      { status: 502 },
    );
  }
}
