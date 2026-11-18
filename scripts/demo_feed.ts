// Builds a demo feed for `-DemoFeed`: the same snapshot sync page the server sends a phone on its
// first pull (−90…+60 days, profile, events, notebook), read from a local copy of a database.
// Usage (see `just demo-feed-prod`):
//   ZONE2_DATABASE_URL=postgres://… deno run -A scripts/demo_feed.ts <out.json> [userId]
// Without userId: the user with the most activities.
import { loadConfig } from "../backend/src/config.ts";
import { createDeps } from "../backend/src/deps.ts";
import { syncPage } from "../backend/src/sync/feed.ts";

const [out, userArg] = Deno.args;
if (!out) throw new Error("usage: demo_feed.ts <out.json> [userId]");
const deps = createDeps(loadConfig());
if (!deps) throw new Error("ZONE2_DATABASE_URL is not set");
try {
  let userId = userArg;
  if (!userId) {
    const [row] = await deps.sql`
      select u.id from zone2.users u
      left join zone2.activities a on a.user_id = u.id
      group by u.id order by count(a.*) desc limit 1`;
    if (!row) throw new Error("no users in the database");
    userId = row.id as string;
  }
  const page = await syncPage(deps, userId, { cursor: null, limit: 1000 });
  await Deno.writeTextFile(out, JSON.stringify(page));
  const counts: Record<string, number> = {};
  for (const c of page.changes) counts[c.entity] = (counts[c.entity] ?? 0) + 1;
  console.log(`user ${userId} →`, out, counts);
} finally {
  await deps.sql.end();
}
