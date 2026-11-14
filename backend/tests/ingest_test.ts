import { assert, assertAlmostEquals, assertEquals, assertExists } from "@std/assert";
import { HealthKitDump, lapsOf, summarize } from "../src/domain/healthkit.ts";
import { gzip } from "../src/ingest/healthkit.ts";
import { makeDump } from "./helpers/dump.ts";
import { mcpHarness } from "./helpers/mcp.ts";

const enc = (d: unknown) => new TextEncoder().encode(JSON.stringify(d));

Deno.test("summary: pace, HR, weather °F→°C, elevation cm→m, laps, pauses", () => {
  const dump = HealthKitDump.parse(
    makeDump({ minutes: 40, distanceM: 8000, segments: 4, pauseSec: 60 }),
  );
  const s = summarize(dump);
  assertEquals(s.sport, "run");
  assertEquals(s.durationSec, 2400);
  assertEquals(s.movingSec, 2340);
  assertEquals(s.paceSecPerKm, Math.round(2340 / 8));
  assertEquals(s.weather?.tempC, -3.4);
  assertEquals(s.weather?.humidityPct, 88);
  assertEquals(s.elevationGainM, 42);
  assertEquals(s.running?.powerAvg, 250);
  assertExists(s.hr);
  const laps = lapsOf(dump);
  assertEquals(laps.length, 4);
  assertAlmostEquals(laps[0].distanceM!, 2000, 1);
});

Deno.test("ingest: upload → activity → plan done; idempotent; Strava copy is a duplicate; Health deletion", async () => {
  const h = await mcpHarness({ now: "2026-11-17T03:00:00Z" });
  try {
    await h.call("update_profile", { patch: { timezone: "Asia/Barnaul" }, why: "пояс" });
    const planned = await h.call("plan_workouts", {
      items: [
        {
          date: "2026-11-16",
          sport: "strength",
          title: "Зал",
          structure: {
            items: [{ type: "exercise", id: "e", exercise: "Присед", sets: 3, reps: 8 }],
          },
        },
        { date: "2026-11-16", sport: "run", title: "Лёгкий 8 км" },
        { date: "2026-11-16", sport: "bike", subSport: "indoor_bike", title: "Станок 60" },
        { date: "2026-11-15", sport: "run", title: "Пропущенный" },
      ],
      why: "план",
    });
    const [, runId, bikeId, missedId] = planned.data.created.map((c: { id: string }) => c.id);

    // Run at 08:00 Barnaul (01:00Z) on the 16th, gzip upload.
    const run = makeDump({ start: "2026-11-16T01:00:00Z", uuid: "RUN-1" });
    const res = await h.api("/v1/activities/healthkit", await gzip(enc(run)), "application/gzip");
    assertEquals(res.status, 201);
    const r = await res.json();
    assertEquals(r.localDate, "2026-11-16");
    assertEquals(r.plannedWorkoutId, runId);

    // Same workout again → same activity, 200.
    const again = await h.api("/v1/activities/healthkit", enc(run));
    assertEquals(again.status, 200);
    assertEquals((await again.json()).activityId, r.activityId);

    // Indoor ride from the watch, then Strava's copy of it → duplicate, plan stays with the watch record.
    const ride = makeDump({
      start: "2026-11-16T12:00:00Z",
      activityType: 13,
      indoor: true,
      minutes: 60,
      uuid: "RIDE-W",
    });
    const rideRes = await (await h.api("/v1/activities/healthkit", enc(ride))).json();
    assertEquals(rideRes.plannedWorkoutId, bikeId);
    const strava = makeDump({
      start: "2026-11-16T12:01:00Z",
      activityType: 13,
      indoor: true,
      minutes: 59,
      uuid: "RIDE-S",
      sourceName: "Strava",
      bundleId: "com.strava.stravaride",
    });
    const stravaRes = await (await h.api("/v1/activities/healthkit", enc(strava))).json();
    assertEquals(stravaRes.duplicateOf, rideRes.activityId);
    assertEquals(stravaRes.plannedWorkoutId, null);

    // Plan statuses: run done, bike done, strength missed? (date passed, nothing matched), 15th missed.
    const plan = (await h.call("get_plan", { from: "2026-11-15", to: "2026-11-16" })).data;
    const status = Object.fromEntries(
      plan.days.flatMap((d: { workouts: { id: string; status: string }[] }) =>
        d.workouts.map((w) => [w.id, w.status])
      ),
    );
    assertEquals(status[runId], "done");
    assertEquals(status[bikeId], "done");
    assertEquals(status[missedId], "missed");

    // MCP: list hides the duplicate; get_activity has summary + plan; streams resample.
    const list = (await h.call("list_activities", {})).data.activities;
    assertEquals(list.length, 2);
    const act = (await h.call("get_activity", { id: r.activityId })).data;
    assertEquals(act.activity.summary.weather.tempC, -3.4);
    assertEquals(act.plan.title, "Лёгкий 8 км");
    assertEquals(act.files[0].kind, "healthkit_dump");
    const st = (await h.call("get_activity_streams", {
      id: r.activityId,
      channels: ["heartRate", "distance", "lat"],
      maxPoints: 40,
    })).data;
    assertEquals(st.columns.t.length, 40);
    assertAlmostEquals(st.columns.distance.at(-1), 8000, 5);
    assert(st.columns.lat[0] > 53);

    // Context shows recent activities and the done status.
    const ctx = (await h.call("get_context")).data;
    assertEquals(ctx.recentActivities.length, 2);

    // Deleted in Health → gone, plan back to missed.
    const del = await h.api("/v1/health-deletions", JSON.stringify({ uuids: ["RUN-1"] }));
    assertEquals((await del.json()).deleted, 1);
    const plan2 = (await h.call("get_plan", { from: "2026-11-16", to: "2026-11-16" })).data;
    const run2 = plan2.days[0].workouts.find((w: { id: string }) => w.id === runId);
    assertEquals(run2.status, "missed");
  } finally {
    await h.drop();
  }
});

Deno.test("sync API: requires app scope; rejects malformed dumps", async () => {
  const h = await mcpHarness();
  try {
    // MCP-scope token cannot upload.
    const res = await h.app.request("/v1/activities/healthkit", {
      method: "POST",
      headers: { authorization: `Bearer ${h.token}`, "content-type": "application/json" },
      body: "{}",
    });
    assertEquals(res.status, 401); // MCP token is bound to the /mcp resource
    const bad = await h.api("/v1/activities/healthkit", JSON.stringify({ schema: 1, workout: {} }));
    assertEquals(bad.status, 422);
    assertEquals((await bad.json()).error, "invalid_dump");
    const me = await h.app.request("/v1/me", {
      headers: { authorization: `Bearer ${h.appToken}` },
    });
    assertEquals((await me.json()).name, "Andrei");
  } finally {
    await h.drop();
  }
});

Deno.test("contract fixture (shared with Swift tests) parses and summarizes", async () => {
  const raw = await Deno.readTextFile(new URL("../../fixtures/healthkit/contract-v1.json", import.meta.url));
  const dump = HealthKitDump.parse(JSON.parse(raw));
  const s = summarize(dump);
  assertEquals(s.sport, "run");
  assertEquals(dump.workout.activities[0].location, "outdoor");
  assertEquals(lapsOf(dump).length, 2);
});
