// GET /v1/sync: snapshot, increments, deletions, re-resolving targets, isolation, cursor errors.
import { assert, assertEquals } from "@std/assert";
import { randomToken, sha256 } from "../src/auth/crypto.ts";
import { gzip } from "../src/ingest/healthkit.ts";
import { makeDump } from "./helpers/dump.ts";
import { mcpHarness } from "./helpers/mcp.ts";

interface Change {
  entity: string;
  id: string;
  op: string;
  version: number;
  // deno-lint-ignore no-explicit-any
  data?: any;
}

Deno.test("sync feed: snapshot, increments, deletes, profile re-resolves upcoming targets", async () => {
  const h = await mcpHarness({ now: "2026-11-14T10:00:00Z" });
  const get = async (q = "", token = h.appToken) => {
    const res = await h.app.request(`/v1/sync${q}`, {
      headers: { authorization: `Bearer ${token}` },
    });
    return { status: res.status, body: await res.json() };
  };
  const find = (changes: Change[], entity: string, id?: string) =>
    changes.filter((c) => c.entity === entity && (id === undefined || c.id === id));
  try {
    await h.call("update_profile", { patch: { run: { lthr: 160 } }, why: "тест" });
    const planned = await h.call("plan_workouts", {
      items: [{
        date: "2026-11-16",
        sport: "run",
        title: "Tempo",
        structure: {
          steps: [{
            type: "step",
            id: "a",
            kind: "work",
            duration: { type: "time", sec: 600 },
            target: { metric: "hr", low: 80, high: 88, unit: "pct_threshold" },
          }],
        },
      }, { date: "2026-11-17", sport: "run", title: "Easy" }],
      why: "тест",
    });
    assert(!planned.isError, JSON.stringify(planned.data));
    const [tempoId, easyId] = planned.data.created.map((c: { id: string }) => c.id);
    const up = await h.api(
      "/v1/activities/healthkit",
      await gzip(
        new TextEncoder().encode(JSON.stringify(makeDump({ start: "2026-11-13T01:00:00Z" }))),
      ),
      "application/gzip",
    );
    assertEquals(up.status, 201);
    const { activityId } = await up.json();

    // Snapshot: profile, both workouts (targets resolved to absolute bpm), the activity.
    const snap = await get();
    assertEquals(snap.status, 200);
    assert(snap.body.snapshot);
    assertEquals(snap.body.hasMore, false);
    const changes = snap.body.changes as Change[];
    assertEquals(find(changes, "profile").length, 1);
    const tempo = find(changes, "planned_workout", tempoId)[0];
    assertEquals(tempo.data.resolved.steps[0].target, {
      metric: "hr",
      low: 128,
      high: 141,
      unit: "abs",
      basis: "run.lthr 160",
    });
    const act = find(changes, "activity", activityId)[0];
    assertEquals(act.data.date, "2026-11-13");
    assertEquals(act.data.summary.v, 7);
    assert(Array.isArray(act.data.laps));
    const cursor = snap.body.cursor;

    // Nothing new → empty page, same cursor.
    const idle = await get(`?cursor=${cursor}`);
    assertEquals(idle.body.changes, []);
    assertEquals(idle.body.cursor, cursor);

    // Two edits of one workout collapse into its current state; a delete arrives as delete.
    await h.call("update_planned_workout", {
      id: easyId,
      patch: { title: "Easy 1" },
      why: "правка",
    });
    await h.call("update_planned_workout", {
      id: easyId,
      patch: { title: "Easy 2" },
      why: "правка",
    });
    const inc = await get(`?cursor=${cursor}`);
    const easy = find(inc.body.changes, "planned_workout", easyId);
    assertEquals(easy.length, 1);
    assertEquals(easy[0].data.title, "Easy 2");
    assertEquals(easy[0].version, 3);
    await h.call("delete_planned_workouts", { ids: [easyId], why: "правка" });
    const del = await get(`?cursor=${inc.body.cursor}`);
    assertEquals(del.body.changes, [{
      entity: "planned_workout",
      id: easyId,
      op: "delete",
      version: 4,
    }]);

    // New threshold → the upcoming %-workout comes again with new absolute targets.
    await h.call("update_profile", { patch: { run: { lthr: 170 } }, why: "тест" });
    const prof = await get(`?cursor=${del.body.cursor}`);
    const again = find(prof.body.changes, "planned_workout", tempoId)[0];
    assertEquals(again.data.resolved.steps[0].target.low, 136);

    // Paging: limit 1 → hasMore, and following pages drain the rest.
    const p1 = await get(`?cursor=${cursor}&limit=1`);
    assertEquals(p1.body.hasMore, true);
    assertEquals(p1.body.changes.length, 1);

    // Activity deleted in Health → delete for the app.
    const [row] = await h.db.sql`select source_id from zone2.activities where id = ${activityId}`;
    await h.api("/v1/health-deletions", JSON.stringify({ uuids: [row.source_id] }));
    const gone = await get(`?cursor=${prof.body.cursor}`);
    assertEquals(find(gone.body.changes, "activity", activityId)[0].op, "delete");

    // Cursor errors and token kinds.
    assertEquals((await get("?cursor=999999")).status, 410);
    assertEquals((await get("?cursor=abc")).status, 400);
    assertEquals((await get("", h.token)).status, 401); // MCP token is bound to /mcp

    // Isolation: another user's app token sees none of this.
    const other = crypto.randomUUID();
    const otherToken = randomToken("z2a");
    await h.db.sql`insert into zone2.users (id, display_name) values (${other}, 'B')`;
    await h.db
      .sql`insert into zone2.oauth_tokens (token_hash, kind, client_id, user_id, scopes, resource, family_id, expires_at)
      values (${await sha256(otherToken)}, 'access', 'zone2-ios', ${other}, ${["app"]}, null,
              ${crypto.randomUUID()}, now() + interval '1 day')`;
    const theirs = await get("", otherToken);
    assertEquals(theirs.status, 200);
    assertEquals(theirs.body.changes, []);
    assertEquals(theirs.body.cursor, "0");
    assertEquals((await get(`?cursor=1`, otherToken)).status, 410); // our seq is not theirs
  } finally {
    await h.drop();
  }
});
