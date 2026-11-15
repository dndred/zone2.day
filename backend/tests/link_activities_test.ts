import { assert, assertEquals, assertStringIncludes } from "@std/assert";
import { makeDump } from "./helpers/dump.ts";
import { BASE, mcpHarness } from "./helpers/mcp.ts";

const enc = (d: unknown) => new TextEncoder().encode(JSON.stringify(d));

type Day = { workouts: { id: string; status: string }[] };
const statuses = (plan: { days: Day[] }) =>
  Object.fromEntries(plan.days.flatMap((d) => d.workouts.map((w) => [w.id, w.status])));

Deno.test("link_activities: plan imported after the fact → missed → linked → done", async () => {
  const h = await mcpHarness({ now: "2026-11-17T03:00:00Z" });
  try {
    await h.call("update_profile", { patch: { timezone: "Asia/Barnaul" }, why: "пояс" });
    // Activities arrive first: nothing to match yet.
    const run = await (await h.api(
      "/v1/activities/healthkit",
      enc(makeDump({ start: "2026-11-16T01:00:00Z", uuid: "RUN-1" })),
    )).json();
    const ride = await (await h.api(
      "/v1/activities/healthkit",
      enc(makeDump({ start: "2026-11-15T12:00:00Z", activityType: 13, uuid: "RIDE-1" })),
    )).json();
    assertEquals(run.plannedWorkoutId, null);

    // Then the plan is imported from another service.
    const planned = await h.call("plan_workouts", {
      items: [
        { date: "2026-11-16", sport: "run", title: "Лёгкий 8 км" },
        { date: "2026-11-15", sport: "run", title: "Длинный" },
      ],
      why: "перенос плана",
    });
    const [easyId, longId] = planned.data.created.map((c: { id: string }) => c.id);
    let plan = (await h.call("get_plan", { from: "2026-11-15", to: "2026-11-16" })).data;
    assertEquals(statuses(plan)[easyId], "missed");

    // dryRun previews, writes nothing.
    const dry = await h.call("link_activities", {
      links: [{ activityId: run.activityId, plannedWorkoutId: easyId }],
      why: "перенос факта",
      dryRun: true,
    });
    assert(!dry.isError, JSON.stringify(dry.data));
    assertEquals(dry.data.changes.length, 1);
    plan = (await h.call("get_plan", { from: "2026-11-15", to: "2026-11-16" })).data;
    assertEquals(statuses(plan)[easyId], "missed");

    // Batch: run → easy; ride → long run (sport mismatch is a warning, not an error).
    const res = await h.call("link_activities", {
      links: [
        { activityId: run.activityId, plannedWorkoutId: easyId },
        { activityId: ride.activityId, plannedWorkoutId: longId },
      ],
      why: "перенос факта",
    });
    assert(!res.isError, JSON.stringify(res.data));
    assertEquals(res.data.changes.length, 2);
    assert(res.data.changes[0].changeId);
    assertEquals(res.data.warnings.length, 1);
    assertStringIncludes(res.data.warnings[0], "bike");
    plan = (await h.call("get_plan", { from: "2026-11-15", to: "2026-11-16" })).data;
    assertEquals(statuses(plan)[easyId], "done");
    assertEquals(statuses(plan)[longId], "done");
    const act = (await h.call("get_activity", { id: run.activityId })).data;
    assertEquals(act.plan.title, "Лёгкий 8 км");

    // Same link again → unchanged, no new change.
    const same = await h.call("link_activities", {
      links: [{ activityId: run.activityId, plannedWorkoutId: easyId }],
      why: "повтор",
    });
    assertEquals(same.data.unchanged, 1);
    assertEquals(same.data.changes.length, 0);

    // Taking a workout someone else holds → conflict with a hint; nothing written.
    const taken = await h.call("link_activities", {
      links: [{ activityId: ride.activityId, plannedWorkoutId: easyId }],
      why: "ошибка",
    });
    assert(taken.isError);
    assertEquals(taken.data.error, "conflict");
    assertStringIncludes(JSON.stringify(taken.data), run.activityId);

    // Moving the link in one call works (unlink the holder in the same batch).
    const moved = await h.call("link_activities", {
      links: [
        { activityId: ride.activityId, plannedWorkoutId: easyId },
        { activityId: run.activityId, plannedWorkoutId: null },
      ],
      why: "перепутал",
    });
    assert(!moved.isError, JSON.stringify(moved.data));
    plan = (await h.call("get_plan", { from: "2026-11-15", to: "2026-11-16" })).data;
    assertEquals(statuses(plan)[longId], "missed");
    assertEquals(statuses(plan)[easyId], "done");

    // Logged for the next chat.
    const changes = (await h.call("get_changes", { entityId: run.activityId })).data;
    assert(JSON.stringify(changes).includes("link_activities"));

    // Unknown ids → not_found.
    const missing = await h.call("link_activities", {
      links: [{ activityId: crypto.randomUUID(), plannedWorkoutId: null }],
      why: "ошибка",
    });
    assertEquals(missing.data.error, "not_found");
  } finally {
    await h.drop();
  }
});

Deno.test("link_activities: users are isolated", async () => {
  const a = await mcpHarness({ now: "2026-11-17T03:00:00Z" });
  try {
    const run = await (await a.api(
      "/v1/activities/healthkit",
      enc(makeDump({ start: "2026-11-16T01:00:00Z", uuid: "RUN-A" })),
    )).json();
    const planned = await a.call("plan_workouts", {
      items: [{ date: "2026-11-10", sport: "run", title: "Чужой" }],
      why: "тест изоляции",
    });
    const plannedId = planned.data.created[0].id;

    // Second user in the same database.
    const other = crypto.randomUUID();
    const { randomToken, sha256 } = await import("../src/auth/crypto.ts");
    const token = randomToken("z2a");
    await a.db.sql`insert into zone2.users (id, display_name) values (${other}, 'B')`;
    await a.db
      .sql`insert into zone2.oauth_tokens (token_hash, kind, client_id, user_id, scopes, resource, family_id, expires_at)
      values (${await sha256(token)}, 'access', 'test-client', ${other}, ${[
      "mcp",
    ]}, ${`${BASE}/mcp`}, ${crypto.randomUUID()}, now() + interval '3650 days')`;
    const callB = async (args: unknown) => {
      const res = await a.app.request("/mcp", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          accept: "application/json, text/event-stream",
          authorization: `Bearer ${token}`,
        },
        body: JSON.stringify({
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: { name: "link_activities", arguments: args },
        }),
      });
      return JSON.parse((await res.json()).result.content[0].text);
    };
    // B cannot touch A's activity, nor link anything to A's planned workout.
    assertEquals(
      (await callB({
        links: [{ activityId: run.activityId, plannedWorkoutId: null }],
        why: "чужое",
      })).error,
      "not_found",
    );
    assertEquals(
      (await callB({
        links: [{ activityId: run.activityId, plannedWorkoutId: plannedId }],
        why: "чужое",
      })).error,
      "not_found",
    );
    const act = (await a.call("get_activity", { id: run.activityId })).data;
    assertEquals(act.activity.plannedWorkoutId, undefined);
  } finally {
    await a.drop();
  }
});
