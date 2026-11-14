import type { Config } from "./config.ts";
import { createSql, type Sql } from "./db/client.ts";
import { AuthStore } from "./auth/store.ts";
import { createWebAuthnPasskeys, type PasskeyService } from "./auth/passkeys.ts";

/** Everything with IO that the app needs. Tests build their own (real DB, fake passkeys). */
export interface AppDeps {
  sql: Sql;
  store: AuthStore;
  passkeys: PasskeyService;
  now: () => Date;
}

export function createDeps(config: Config): AppDeps | undefined {
  if (!config.databaseUrl) return undefined;
  const sql = createSql(config.databaseUrl);
  return {
    sql,
    store: new AuthStore(sql),
    passkeys: createWebAuthnPasskeys({
      rpId: config.rpId,
      rpName: "zone2.day",
      origin: new URL(config.publicBaseUrl).origin,
    }),
    now: () => new Date(),
  };
}
