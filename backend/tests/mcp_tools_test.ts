import { assert, assertEquals, assertExists, assertStringIncludes } from "@std/assert";
import { mcpHarness } from "./helpers/mcp.ts";

const run = {
  date: "2026-11-16",
  sport: "run",
  title: "10 км + 6×12 с в горку",
  goal: "Нервно-мышечная сила",
  structure: {
    steps: [
      {
        type: "step",
        id: "wu",
        kind: "warmup",
        duration: { type: "distance", m: 3500 },
        target: { metric: "hr", low: 125, high: 145 },
      },
      {
        type: "repeat",
        id: "r",
        count: 6,
        steps: [
          {
            type: "step",
            id: "w",
            kind: "work",
            duration: { type: "time", sec: 12 },
            target: { metric: "rpe", low: 9, high: 10 },
          },
          {
            type: "step",
            id: "rec",
            kind: "recovery",
            duration: { type: "time", sec: 105 },
            target: { metric: "hr", high: 140 },
          },
        ],
      },
      { type: "step", id: "cd", kind: "cooldown", duration: { type: "open" } },
    ],
  },
};
const gym = {
  date: "2026-11-16",
  sport: "strength",
  title: "Зал A",
  structure: {
    items: [{
      type: "exercise",
      id: "rdl",
      exercise: "Румынская тяга",
      sets: 2,
      reps: 8,
      weightKg: 55,
      rpe: 6,
    }],
  },
};

Deno.test("coach flow: context → profile → week → plan → skip → copy → revert", async () => {
  const h = await mcpHarness({ now: "2026-11-14T15:00:00Z" });
  try {
    // Empty account: context works and asks for the time zone.
    let ctx = (await h.call("get_context")).data;
    assertEquals(ctx.timezoneUnset, true);
    assertEquals(ctx.plan, []);

    // Profile: home zone + a trip + a threshold range.
    const prof = await h.call("update_profile", {
      patch: {
        timezone: "Asia/Barnaul",
        travel: [{ from: "2027-05-28", to: "2027-06-04", timezone: "Europe/Moscow", note: "СПб" }],
        run: { lthr: { low: 156, high: 162, basis: "отрезки 8–10 мин" } },
      },
      why: "Атлет рассказал про пороги и поездку",
    });
    assert(!prof.isError, JSON.stringify(prof.data));
    ctx = (await h.call("get_context")).data;
    assertEquals(ctx.now.timezone, "Asia/Barnaul");
    assertEquals(ctx.now.date, "2026-11-14"); // 22:00 local
    assertEquals(ctx.timezoneUnset, undefined);

    // Week header.
    const wk = await h.call("upsert_week", {
      weekStart: "2026-11-16",
      title: "БАЗА — неделя 1",
      header: "Вектор: объём Z2",
    });
    assert(!wk.isError, JSON.stringify(wk.data));

    // Plan: gym first, run second on the same day (order assigned automatically).
    const planned = await h.call("plan_workouts", {
      items: [gym, run],
      why: "Старт базового блока",
    });
    assert(!planned.isError, JSON.stringify(planned.data));
    const [gymId, runId] = planned.data.created.map((c: { id: string }) => c.id);

    const plan = (await h.call("get_plan", { from: "2026-11-16", to: "2026-11-22" })).data;
    assertEquals(plan.weeks[0].title, "БАЗА — неделя 1");
    const day = plan.days[0].workouts;
    assertEquals(day.map((w: { title: string }) => w.title), ["Зал A", "10 км + 6×12 с в горку"]);
    assertEquals(day[1].execution, "workoutkit");
    assertEquals(day[0].execution, "none");
    assertEquals(day[1].lastChange.why, "Старт базового блока");
    assertEquals(day[1].estimate.durationSec, 702); // 6 × 117 s known; warmup distance has no pace

    // Full workout with resolved targets and history.
    const full = (await h.call("get_planned_workout", { id: runId })).data;
    assertEquals(full.workout.title, run.title);
    assertEquals(full.history.length, 1);

    // Skip with reason, then context shows it.
    const skip = await h.call("update_planned_workout", {
      id: gymId,
      patch: { skipped: { reason: "Крепатура после бега" } },
      why: "Атлет пропустил зал",
    });
    assertEquals(skip.data.updated.status, "skipped");

    // Copy the day a week later.
    const copy = await h.call("copy_planned_workouts", {
      fromDate: "2026-11-16",
      toDate: "2026-11-16",
      shiftDays: 7,
      why: "Повтор недели",
    });
    assertEquals(copy.data.created.length, 2);
    const next = (await h.call("get_plan", { from: "2026-11-23", to: "2026-11-23" })).data;
    assertEquals(
      next.days[0].workouts.every((w: { status: string }) => w.status === "planned"),
      true,
    );

    // Revert the skip.
    const changes =
      (await h.call("get_changes", { entity: "planned_workout", entityId: gymId })).data.changes;
    assertEquals(changes[0].why, "Атлет пропустил зал");
    const rev = await h.call("revert_change", {
      changeId: changes[0].changeId,
      why: "Ошибся, зал был",
    });
    assert(!rev.isError, JSON.stringify(rev.data));
    const after = (await h.call("get_planned_workout", { id: gymId })).data;
    assertEquals(after.workout.skipped, undefined);

    // Reverting twice is a conflict.
    const again = await h.call("revert_change", { changeId: changes[0].changeId, why: "ещё раз" });
    assert(again.isError);
    assertEquals(again.data.error, "conflict");
  } finally {
    await h.drop();
  }
});

Deno.test("validation errors are explicit and nothing is saved", async () => {
  const h = await mcpHarness();
  try {
    const bad = structuredClone(run);
    (bad.structure.steps[0] as { target: unknown }).target = { metric: "hr", low: 150, high: 140 };
    const r = await h.call("plan_workouts", { items: [gym, bad], why: "тест" });
    assert(r.isError);
    const text = JSON.stringify(r.data);
    assertStringIncludes(text, "target.low must be ≤ target.high");
    const plan = (await h.call("get_plan", { from: "2026-11-16", to: "2026-11-16" })).data;
    assertEquals(plan.days, []);

    const wrongSport = await h.call("plan_workouts", {
      items: [{ ...gym, sport: "run" }],
      why: "тест",
    });
    assert(wrongSport.isError);
  } finally {
    await h.drop();
  }
});

Deno.test("events, journal, notebook", async () => {
  const h = await mcpHarness({ now: "2026-11-14T03:00:00Z" });
  try {
    await h.call("update_profile", { patch: { timezone: "Asia/Barnaul" }, why: "пояс" });

    const idea = await h.call("upsert_event", {
      fields: {
        name: "Бревет 200",
        sport: "brevet",
        status: "idea",
        datePrecision: "month_part",
        dateFrom: "2027-06-01",
        dateTo: "2027-06-10",
        dateText: "начало июня 2027",
        distanceM: 200000,
      },
    });
    assert(!idea.isError, JSON.stringify(idea.data));
    const race = await h.call("upsert_event", {
      fields: {
        name: "Полумарафон",
        sport: "run",
        status: "registered",
        priority: "A",
        datePrecision: "day",
        dateFrom: "2027-05-30",
        dateTo: "2027-05-30",
        timezone: "Europe/Moscow",
      },
    });
    assert(!race.isError, JSON.stringify(race.data));

    const open = await h.call("write_journal", {
      date: "2026-11-13",
      text: "Мигрень вечером",
      tags: ["migraine"],
    });
    const q = await h.call("write_journal", {
      date: "2026-11-14",
      text: "Подобрать кроссовки на зиму",
      tags: ["gear"],
      due: "2026-11-30",
    });
    assert(!open.isError && !q.isError);

    await h.call("write_notebook", {
      slug: "athlete",
      title: "Атлет",
      content: "Бег → триатлон.",
      pinned: true,
    });
    await h.call("write_notebook", {
      slug: "athlete",
      content: "Ultra 2, MyWhoosh.",
      mode: "append",
    });
    await h.call("write_notebook", {
      slug: "fuel",
      title: "Питание",
      content: "60 г/ч на длинных",
    });

    const ctx = (await h.call("get_context")).data;
    assertEquals(ctx.events.upcoming.map((e: { name: string }) => e.name), ["Полумарафон"]);
    assertEquals(ctx.events.ideas[0].dateText, "начало июня 2027");
    assertEquals(ctx.journal.open.length, 1);
    assertEquals(ctx.journal.recent[0].tags, ["migraine"]);
    assertEquals(ctx.notebook.pinned[0].content, "Бег → триатлон.\n\nUltra 2, MyWhoosh.");
    assertEquals(ctx.notebook.others, [{ slug: "fuel", title: "Питание" }]);

    // Close the open question.
    const closed = await h.call("write_journal", { id: q.data.entry.id, close: true });
    assertExists(closed.data.entry.closedAt);
    assertEquals((await h.call("list_journal", { open: true })).data.entries, []);

    // Patch requires exact text.
    const miss = await h.call("write_notebook", {
      slug: "fuel",
      mode: "patch",
      find: "90 г/ч",
      content: "x",
    });
    assertEquals(miss.data.error, "patch_failed");
  } finally {
    await h.drop();
  }
});

Deno.test("users are isolated", async () => {
  const a = await mcpHarness();
  try {
    const planned = await a.call("plan_workouts", { items: [gym], why: "тест изоляции" });
    const id = planned.data.created[0].id;
    // Second user in the same database.
    const other = crypto.randomUUID();
    const { randomToken, sha256 } = await import("../src/auth/crypto.ts");
    const token = randomToken("z2a");
    await a.db.sql`insert into zone2.users (id, display_name) values (${other}, 'B')`;
    await a.db
      .sql`insert into zone2.oauth_tokens (token_hash, kind, client_id, user_id, scopes, resource, family_id, expires_at)
      values (${await sha256(token)}, 'access', 'test-client', ${other}, ${[
      "mcp",
    ]}, null, ${crypto.randomUUID()}, now() + interval '1 day')`;
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
        params: { name: "get_planned_workout", arguments: { id } },
      }),
    });
    const body = await res.json();
    assertEquals(JSON.parse(body.result.content[0].text).error, "not_found");
  } finally {
    await a.drop();
  }
});

Deno.test("review fixes (agent report 2026-11-14)", async () => {
  const h = await mcpHarness({ now: "2026-11-14T16:37:00Z" });
  try {
    const step = (target: Record<string, unknown>) => ({
      steps: [{
        type: "step",
        id: "a",
        kind: "work",
        duration: { type: "time", sec: 600 },
        target,
      }],
    });

    // 1. %-target without threshold → saved, but with a warning naming the item and step.
    const pct = await h.call("plan_workouts", {
      items: [{
        date: "2026-11-16",
        sport: "run",
        title: "Tempo",
        structure: step({ metric: "hr", low: 80, high: 88, unit: "pct_threshold" }),
      }],
      why: "тест",
    });
    assert(!pct.isError, JSON.stringify(pct.data));
    assertEquals(pct.data.warnings[0].item, 0);
    assertEquals(pct.data.warnings[0].stepId, "a");
    const runId = pct.data.created[0].id;

    // 2. Errors point at the item index.
    const bad = await h.call("plan_workouts", {
      items: [gym, gym, gym, {
        ...run,
        structure: { steps: [{ type: "repeat", id: "r", count: 0, steps: [] }] },
      }],
      why: "тест",
    });
    assert(bad.isError);
    assertStringIncludes(JSON.stringify(bad.data), "items.3.structure");

    // 3. Nonsense combinations are rejected.
    const swimPower = await h.call("plan_workouts", {
      items: [{
        date: "2026-11-17",
        sport: "swim",
        title: "Swim",
        structure: step({ metric: "power", low: 100, high: 120 }),
      }],
      why: "тест",
    });
    assert(swimPower.isError);
    assertStringIncludes(JSON.stringify(swimPower.data), "does not apply to swim");
    const runMywhoosh = await h.call("plan_workouts", {
      items: [{ date: "2026-11-17", sport: "run", title: "Run", execution: "mywhoosh" }],
      why: "тест",
    });
    assert(runMywhoosh.isError);
    const strengthWk = await h.call("plan_workouts", {
      items: [{ ...gym, execution: "workoutkit" }],
      why: "тест",
    });
    assert(strengthWk.isError);
    const runPower = await h.call("plan_workouts", {
      items: [{
        date: "2026-11-17",
        sport: "run",
        title: "Run power",
        structure: step({ metric: "power", low: 250, high: 270 }),
      }],
      why: "running power is measured by Apple Watch",
    });
    assert(!runPower.isError, JSON.stringify(runPower.data));

    // 4. overriddenLaterChanges counts only later edits.
    const upd = await h.call("update_planned_workout", {
      id: runId,
      patch: { title: "Tempo 2" },
      why: "правка",
    });
    const lastChange = upd.data.updated.changeId;
    const revLast = await h.call("revert_change", { changeId: lastChange, why: "откат последней" });
    assertEquals(revLast.data.overriddenLaterChanges, 0);
    const createChange = pct.data.created[0].changeId;
    const revCreate = await h.call("revert_change", {
      changeId: createChange,
      why: "откат создания",
    });
    assertEquals(revCreate.data.overriddenLaterChanges, 2); // update + its revert

    // 9. Deleted workout is still readable with deleted:true and history.
    const del = (await h.call("get_planned_workout", { id: runId })).data;
    assertEquals(del.deleted, true);
    assertEquals(del.status, "deleted");
    assert(del.history.length >= 3);

    // 5 + 6. update_profile returns fresh `now`; first change is an update of the defaults.
    const prof = await h.call("update_profile", {
      patch: { timezone: "Asia/Barnaul" },
      why: "пояс",
    });
    assertEquals(prof.data.now.timezone, "Asia/Barnaul");
    assertEquals(prof.data.now.time, "23:37");
    const profChange = (await h.call("get_changes", { entity: "profile" })).data.changes[0];
    assertEquals(profChange.op, "update");

    // 7. copy returns changeIds.
    const g = await h.call("plan_workouts", { items: [gym], why: "зал" });
    const copy = await h.call("copy_planned_workouts", {
      ids: [g.data.created[0].id],
      shiftDays: 7,
      why: "повтор",
    });
    assertExists(copy.data.created[0].changeId);

    // 8. get_planned_workout shows status.
    await h.call("update_planned_workout", {
      id: g.data.created[0].id,
      patch: { skipped: { reason: "болел" } },
      why: "пропуск",
    });
    const sk = (await h.call("get_planned_workout", { id: g.data.created[0].id })).data;
    assertEquals(sk.status, "skipped");
  } finally {
    await h.drop();
  }
});
