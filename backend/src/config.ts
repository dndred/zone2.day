import { z } from "zod";

/** Runtime configuration. Read once at startup from environment variables. */
const ConfigSchema = z.object({
  env: z.enum(["local", "staging", "prod", "test"]),
  /** Build identifier (git sha) — lets the agent verify which build is live. */
  version: z.string().min(1),
  /** Public origin clients see, e.g. https://api.zone2.day (no trailing slash). */
  publicBaseUrl: z.url().transform((u) => u.replace(/\/$/, "")),
});

export type Config = z.infer<typeof ConfigSchema>;

export type EnvReader = (name: string) => string | undefined;

export function loadConfig(read: EnvReader = (n) => Deno.env.get(n)): Config {
  return ConfigSchema.parse({
    env: read("ZONE2_ENV") ?? "local",
    version: read("ZONE2_VERSION") ?? "dev",
    publicBaseUrl: read("ZONE2_PUBLIC_BASE_URL") ?? "http://localhost:8787",
  });
}
