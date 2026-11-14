// Throwaway Postgres database per test run, with the real Supabase migrations applied.
// Needs the test container: `just test-db-up` (postgres on localhost:54329).
import postgres from "postgres";
import { createSql, type Sql } from "../../src/db/client.ts";

const ADMIN_URL = Deno.env.get("ZONE2_TEST_DATABASE_URL") ??
  "postgres://postgres:postgres@localhost:54329/postgres";
const MIGRATIONS_DIR = new URL("../../../supabase/migrations/", import.meta.url);

export interface TestDb {
  sql: Sql;
  url: string;
  drop: () => Promise<void>;
}

export async function createTestDb(): Promise<TestDb> {
  const admin = postgres(ADMIN_URL, { max: 1, onnotice: () => {} });
  const name = `zone2_test_${crypto.randomUUID().replaceAll("-", "").slice(0, 12)}`;
  await admin.unsafe(`create database ${name}`);
  const url = ADMIN_URL.replace(/\/[^/?]*(\?|$)/, `/${name}$1`);
  const sql = createSql(url, { max: 2 });

  const files = [...Deno.readDirSync(MIGRATIONS_DIR)]
    .filter((e) => e.isFile && e.name.endsWith(".sql"))
    .map((e) => e.name)
    .sort();
  for (const f of files) await sql.unsafe(await Deno.readTextFile(new URL(f, MIGRATIONS_DIR)));

  return {
    sql,
    url,
    drop: async () => {
      await sql.end();
      await admin.unsafe(`drop database if exists ${name} with (force)`);
      await admin.end();
    },
  };
}
