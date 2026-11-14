import { z } from "zod";

/** Runtime configuration. Read once at startup from environment variables. */
const ConfigSchema = z.object({
  env: z.enum(["local", "staging", "prod", "test"]),
  /** Build identifier (git sha) — lets the agent verify which build is live. */
  version: z.string().min(1),
  /** Public origin clients see, e.g. https://api.zone2.day (no trailing slash). OAuth issuer. */
  publicBaseUrl: z.url().transform((u) => u.replace(/\/$/, "")),
  /** WebAuthn relying party id: "zone2.day" in staging/prod so passkeys survive host changes. */
  rpId: z.string().min(1),
  /** HMAC key for signed authorization requests. ≥32 chars; from 1Password → secrets. */
  secretKey: z.string().min(32),
  /** Postgres connection string. Supabase injects SUPABASE_DB_URL into Edge Functions. */
  databaseUrl: z.string().min(1).optional(),
  /** Supabase Storage for raw files; without it an in-memory store is used (local/dev). */
  supabaseUrl: z.string().min(1).optional(),
  supabaseServiceKey: z.string().min(1).optional(),
});

export type Config = z.infer<typeof ConfigSchema>;

export type EnvReader = (name: string) => string | undefined;

const INSECURE_DEV_SECRET = "insecure-local-dev-secret-key-do-not-use-in-prod";

export function loadConfig(read: EnvReader = (n) => Deno.env.get(n)): Config {
  const env = read("ZONE2_ENV") ?? "local";
  const publicBaseUrl = read("ZONE2_PUBLIC_BASE_URL") ?? "http://localhost:8787";
  const devLike = env === "local" || env === "test";
  return ConfigSchema.parse({
    env,
    version: read("ZONE2_VERSION") ?? "dev",
    publicBaseUrl,
    rpId: read("ZONE2_RP_ID") ?? safeHostname(publicBaseUrl),
    secretKey: read("ZONE2_SECRET_KEY") ?? (devLike ? INSECURE_DEV_SECRET : undefined),
    databaseUrl: read("ZONE2_DATABASE_URL") ?? read("SUPABASE_DB_URL"),
    supabaseUrl: read("SUPABASE_URL"),
    supabaseServiceKey: read("SUPABASE_SERVICE_ROLE_KEY"),
  });
}

function safeHostname(url: string): string {
  try {
    return new URL(url).hostname;
  } catch {
    return "localhost";
  }
}
