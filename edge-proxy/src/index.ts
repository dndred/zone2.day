// Cloudflare Worker entry point.
import { proxy, type ProxyEnv } from "./proxy.ts";

export default {
  fetch(req: Request, env: ProxyEnv): Promise<Response> {
    return proxy(req, env);
  },
};
