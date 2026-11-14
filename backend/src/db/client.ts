import postgres from "postgres";

export type Sql = postgres.Sql;

/**
 * Postgres client. `prepare: false` keeps it compatible with transaction-mode poolers
 * (Supavisor/PgBouncer). Small pool: an Edge Function isolate serves few concurrent requests.
 */
export function createSql(url: string, opts: { max?: number } = {}): Sql {
  return postgres(url, {
    prepare: false,
    max: opts.max ?? 3,
    idle_timeout: 20,
    connect_timeout: 10,
    onnotice: () => {},
  });
}
