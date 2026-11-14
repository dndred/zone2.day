// Local / VPS entry point: plain Deno HTTP server.
import { createApp } from "../app.ts";
import { loadConfig } from "../config.ts";
import { log } from "../log.ts";

const config = loadConfig();
const port = Number(Deno.env.get("PORT") ?? 8787);
const app = createApp(config);

Deno.serve(
  { port, onListen: () => log("info", "listening", { port, env: config.env }) },
  app.fetch,
);
