// revert_change for activities and strength sessions; strength date/plan checks; profile keys.
import { assert, assertEquals, assertStringIncludes } from "@std/assert";
import { mcpHarness } from "./helpers/mcp.ts";

Deno.test("revert_change: created activity and its link, logged strength session", async () => {
  const h = await mcpHarness({ now: "2026-11-16T10:00:00Z" });
  try {
    const plan = await h.call("plan_workouts", {
      items: [
        { date: "2026-11-16", sport: "run", title: "Лёгкий" },
        { date: "2026-11-16", sport: "strength", title: "Зал", execution: "none" },
      ],
      why: "план",
    });
    const [runId, gymId] = plan.data.created.map((c: { id: string }) => c.id);
    const status = async (id: string) => (await h.call("get_planned_workout", { id })).data.status;

    // Activity: create (auto-matched) → unlink → revert unlink → revert create → revert that.
    const act = await h.call("create_activity", {
      sport: "run",
      start: "2026-11-16T07:00",
      durationSec: 1800,
      why: "атлет рассказал",
    });
    assert(!act.isError, JSON.stringify(act.data));
    const actId = act.data.activity.id;
    assertEquals(act.data.activity.plannedWorkoutId, runId);

    const unlink = await h.call("link_activities", {
      links: [{ activityId: actId, plannedWorkoutId: null }],
      why: "не та",
    });
    const relink = await h.call("revert_change", {
      changeId: unlink.data.changes[0].changeId,
      why: "та самая",
    });
    assert(!relink.isError, JSON.stringify(relink.data));
    assertEquals(relink.data.op, "update");
    assertEquals(
      (await h.call("get_activity", { id: actId })).data.activity.plannedWorkoutId,
      runId,
    );

    const del = await h.call("revert_change", { changeId: act.data.changeId, why: "тест" });
    assert(!del.isError, JSON.stringify(del.data));
    assertEquals(del.data.op, "delete");
    assertEquals(del.data.overriddenLaterChanges, 2); // the unlink and its revert
    assertEquals((await h.call("list_activities", {})).data.activities, []);
    assertEquals(await status(runId), "planned");
    const twice = await h.call("revert_change", { changeId: act.data.changeId, why: "ещё" });
    assertEquals(twice.data.error, "conflict");

    const back = await h.call("revert_change", { changeId: del.data.newChangeId, why: "вернуть" });
    assert(!back.isError, JSON.stringify(back.data));
    assertEquals(back.data.op, "create");
    assertEquals((await h.call("list_activities", {})).data.activities.length, 1);
    assertEquals(await status(runId), "done");

    // Strength: future date refused, wrong plan refused, logged session reverted and restored.
    const future = await h.call("log_strength_session", {
      date: "2026-11-17",
      plannedWorkoutId: gymId,
      sets: [{ exercise: "Присед", reps: 5, weightKg: 60 }],
      why: "тест",
    });
    assertEquals(future.data.error, "bad_input");
    assertStringIncludes(future.data.message, "future");
    const notStrength = await h.call("log_strength_session", {
      date: "2026-11-16",
      plannedWorkoutId: runId,
      sets: [{ exercise: "Присед", reps: 5 }],
      why: "тест",
    });
    assertEquals(notStrength.data.error, "bad_input");
    assertEquals(
      (await h.call("log_strength_session", {
        date: "2026-11-16",
        plannedWorkoutId: crypto.randomUUID(),
        sets: [{ exercise: "Присед", reps: 5 }],
        why: "тест",
      })).data.error,
      "not_found",
    );
    assertEquals(await status(gymId), "planned");

    const lift = await h.call("log_strength_session", {
      date: "2026-11-16",
      plannedWorkoutId: gymId,
      sets: [{ exercise: "Присед", reps: 5, weightKg: 60 }],
      why: "из заметок",
    });
    assert(!lift.isError, JSON.stringify(lift.data));
    assertEquals(await status(gymId), "done");
    const undo = await h.call("revert_change", { changeId: lift.data.changeId, why: "дубль" });
    assert(!undo.isError, JSON.stringify(undo.data));
    assertEquals((await h.call("get_strength_log", {})).data.sessions, []);
    assertEquals(await status(gymId), "planned");
    const redo = await h.call("revert_change", { changeId: undo.data.newChangeId, why: "нет" });
    assert(!redo.isError, JSON.stringify(redo.data));
    assertEquals((await h.call("get_strength_log", {})).data.sessions.length, 1);

    // Deleting the plan hides the link in the log; reverting the deletion brings it back.
    const gone = await h.call("delete_planned_workouts", { ids: [gymId], why: "убрать" });
    let log = (await h.call("get_strength_log", {})).data.sessions;
    assertEquals(log[0].plannedWorkoutId, undefined);
    await h.call("revert_change", { changeId: gone.data.deleted[0].changeId, why: "вернуть" });
    log = (await h.call("get_strength_log", {})).data.sessions;
    assertEquals(log[0].plannedWorkoutId, gymId);

    // Another user cannot revert our changes.
    const other = await mcpHarness({ now: "2026-11-16T10:00:00Z" });
    try {
      const foreign = await other.call("revert_change", {
        changeId: lift.data.changeId,
        why: "тест",
      });
      assertEquals(foreign.data.error, "not_found");
    } finally {
      await other.drop();
    }
  } finally {
    await h.drop();
  }
});

Deno.test("update_profile: unknown keys refused with a suggestion, null removes", async () => {
  const h = await mcpHarness();
  try {
    const bad = await h.call("update_profile", {
      patch: { run: { thresholdPace: 270 } },
      why: "порог",
    });
    assertEquals(bad.data.error, "unknown_field");
    assertStringIncludes(bad.data.hint, "run.thresholdPaceSecPerKm");
    const typo = await h.call("update_profile", { patch: { timezon: "UTC" }, why: "тест" });
    assertStringIncludes(typo.data.hint, "timezone");

    const ok = await h.call("update_profile", {
      patch: { run: { thresholdPaceSecPerKm: 270, maxHr: 190 } },
      why: "порог",
    });
    assert(!ok.isError, JSON.stringify(ok.data));
    const cleared = await h.call("update_profile", {
      patch: { run: { maxHr: null, thresholdPaceSecPerKm: null } },
      why: "убрать",
    });
    assertEquals(cleared.data.profile.run.maxHr, undefined);
    assertEquals(cleared.data.profile.run.thresholdPaceSecPerKm, null); // null = "unknown"
    // A stray key saved before validation existed can be removed with null.
    const stray = await h.call("update_profile", {
      patch: { run: { thresholdPace: null } },
      why: "тест",
    });
    assert(!stray.isError, JSON.stringify(stray.data));
  } finally {
    await h.drop();
  }
});
