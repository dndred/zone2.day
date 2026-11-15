// Strength log: phone snapshots, plan status, MCP log/history/update/merge, feed, isolation.
import { assert, assertEquals, assertStringIncludes } from "@std/assert";
import { randomToken, sha256 } from "../src/auth/crypto.ts";
import { mcpHarness } from "./helpers/mcp.ts";

Deno.test("strength: app sessions, MCP tools, feed, isolation", async () => {
  const h = await mcpHarness({ now: "2026-11-16T10:00:00Z" });
  const getSync = async (q = "", token = h.appToken) =>
    await (await h.app.request(`/v1/sync${q}`, { headers: { authorization: `Bearer ${token}` } }))
      .json();
  try {
    const planned = await h.call("plan_workouts", {
      items: [{
        date: "2026-11-16",
        sport: "strength",
        title: "Зал A",
        execution: "none",
        structure: {
          items: [{
            type: "exercise",
            id: "sq",
            exercise: "Присед",
            sets: 2,
            reps: 8,
            weightKg: 60,
          }],
        },
      }],
      why: "силовая",
    });
    assert(!planned.isError, JSON.stringify(planned.data));
    const gymId = planned.data.created[0].id;
    const cursor = (await getSync()).cursor;

    // The phone logs the session: set 1 as planned, set 2 heavier with fewer reps, plank.
    const sessionId = crypto.randomUUID();
    const [s1, s2, s3] = [crypto.randomUUID(), crypto.randomUUID(), crypto.randomUUID()];
    const body = {
      id: sessionId,
      plannedWorkoutId: gymId,
      date: "2026-11-16",
      sets: [
        {
          id: s1,
          exercise: "Присед",
          order: 0,
          setIndex: 0,
          planned: { reps: 8, weightKg: 60 },
          actual: { reps: 8, weightKg: 60 },
        },
        {
          id: s2,
          exercise: "Присед",
          order: 0,
          setIndex: 1,
          planned: { reps: 8, weightKg: 60 },
          actual: { reps: 6, weightKg: 65 },
          rpe: 8,
        },
        {
          id: s3,
          exercise: "Планка",
          order: 1,
          setIndex: 0,
          planned: { holdSec: 45 },
          actual: null,
        },
      ],
    };
    let r = await h.api("/v1/strength-sessions", JSON.stringify(body));
    assertEquals(r.status, 200);
    r = await h.api("/v1/strength-sessions", JSON.stringify(body)); // idempotent resend
    assertEquals((await r.json()).sets, 3);

    const plan = (await h.call("get_plan", { from: "2026-11-16", to: "2026-11-16" })).data;
    assertEquals(plan.days[0].workouts[0].status, "done");

    const log = (await h.call("get_strength_log", {})).data.sessions[0];
    assertEquals(log.source, "app");
    assertEquals(log.exercises[0].sets.map((x: { actual: string }) => x.actual), ["60×8", "65×6"]);
    assertEquals(log.exercises[1].missed, 1);

    // Coach moves an older session over from notes, under another name, then merges names.
    const old = await h.call("log_strength_session", {
      date: "2026-11-09",
      sets: [
        { exercise: "Приседания со штангой", reps: 8, weightKg: 55 },
        { exercise: "Приседания со штангой", reps: 8, weightKg: 57.5, rpe: 7 },
      ],
      notes: "из Notion",
      why: "перенос истории весов",
    });
    assert(!old.isError, JSON.stringify(old.data));
    let hist = (await h.call("get_exercise_history", { exercise: "Присед" })).data;
    assertEquals(hist.sessions.length, 1);
    const merged = await h.call("merge_exercises", {
      names: ["Приседания со штангой"],
      into: "Присед",
      why: "одно движение",
    });
    assertEquals(merged.data.movedSets, 2);
    hist = (await h.call("get_exercise_history", { exercise: "приседания со штангой" })).data; // alias works
    assertEquals(hist.exercise, "Присед");
    assertEquals(hist.sessions.map((x: { date: string }) => x.date), ["2026-11-16", "2026-11-09"]);
    assertEquals(hist.sessions[0].best, "65×6");
    assertEquals(hist.sessions[0].e1rmKg, 78); // 65 × (1 + 6/30)
    assertEquals(hist.sessions[0].vsPlan, "below plan");
    assertEquals(hist.gapsDays, [7]);

    // Athlete: "second set was 62.5, not 65" → fix; audit visible; revert refuses.
    const upd = await h.call("update_strength_log", {
      sessionId,
      sets: [{ id: s2, weightKg: 62.5 }],
      why: "атлет поправил вес",
    });
    assert(!upd.isError, JSON.stringify(upd.data));
    assertEquals(upd.data.session.exercises[0].sets[1].actual, "62.5×6");
    const changes = (await h.call("get_changes", { limit: 5 })).data;
    assertStringIncludes(JSON.stringify(changes), "атлет поправил вес");
    const rev = await h.call("revert_change", { changeId: upd.data.changeId, why: "проверка" });
    assert(rev.isError);
    assertStringIncludes(JSON.stringify(rev.data), "update_strength_log");

    // Feed carries sessions to the app.
    const inc = await getSync(`?cursor=${cursor}`);
    const lift = inc.changes.find((c: { entity: string; id: string }) =>
      c.entity === "strength_session" && c.id === sessionId
    );
    assertEquals(lift.op, "upsert");
    assertEquals(lift.data.sets.length, 3);
    assertEquals(lift.data.sets[1].actual.weightKg, 62.5);

    // Isolation: another user cannot overwrite our session id nor see our log.
    const other = crypto.randomUUID();
    const otherToken = randomToken("z2a");
    await h.db.sql`insert into zone2.users (id, display_name) values (${other}, 'B')`;
    await h.db
      .sql`insert into zone2.oauth_tokens (token_hash, kind, client_id, user_id, scopes, resource, family_id, expires_at)
      values (${await sha256(otherToken)}, 'access', 'zone2-ios', ${other}, ${["app"]}, null,
              ${crypto.randomUUID()}, now() + interval '3650 days')`;
    const hijack = await h.app.request("/v1/strength-sessions", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${otherToken}` },
      body: JSON.stringify({ ...body, sets: [] }),
    });
    assertEquals(hijack.status, 409);
    const theirs = await getSync("", otherToken);
    assertEquals(
      theirs.changes.filter((c: { entity: string }) => c.entity === "strength_session"),
      [],
    );
    assertEquals((await h.api("/v1/strength-sessions", JSON.stringify({ id: "x" }))).status, 400);
  } finally {
    await h.drop();
  }
});
