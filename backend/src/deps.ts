import type { Config } from "./config.ts";
import { createSql, type Sql } from "./db/client.ts";
import { AuthStore } from "./auth/store.ts";
import { DocumentStore } from "./db/documents.ts";
import { ActivityStore } from "./db/activities.ts";
import { DeliveryStore } from "./db/deliveries.ts";
import { StrengthStore } from "./db/strength.ts";
import { type BlobStore, MemoryBlobStore } from "./ports/blob.ts";
import { SupabaseStorage } from "./adapters/supabase_storage.ts";
import { createWebAuthnPasskeys, type PasskeyService } from "./auth/passkeys.ts";

/** Everything with IO that the app needs. Tests build their own (real DB, fake passkeys). */
export interface AppDeps {
  sql: Sql;
  store: AuthStore;
  docs: DocumentStore;
  activities: ActivityStore;
  deliveries: DeliveryStore;
  strength: StrengthStore;
  blobs: BlobStore;
  passkeys: PasskeyService;
  now: () => Date;
}

export function createDeps(config: Config): AppDeps | undefined {
  if (!config.databaseUrl) return undefined;
  const sql = createSql(config.databaseUrl);
  return {
    sql,
    store: new AuthStore(sql),
    docs: new DocumentStore(sql),
    activities: new ActivityStore(sql),
    deliveries: new DeliveryStore(sql),
    strength: new StrengthStore(sql),
    blobs: config.supabaseUrl && config.supabaseServiceKey
      ? new SupabaseStorage(config.supabaseUrl, config.supabaseServiceKey, "activity-files")
      : new MemoryBlobStore(),
    passkeys: createWebAuthnPasskeys({
      rpId: config.rpId,
      rpName: "zone2.day",
      origin: new URL(config.publicBaseUrl).origin,
    }),
    now: () => new Date(),
  };
}
