import { assert, assertAlmostEquals, assertEquals } from "@std/assert";
import {
  HealthKitDump,
  lapsOf,
  streams,
  summarize,
  SUMMARY_VERSION,
} from "../src/domain/healthkit.ts";
import { gzip } from "../src/ingest/healthkit.ts";
import { makeDump } from "./helpers/dump.ts";
import { mcpHarness } from "./helpers/mcp.ts";
import type { ActivityRow } from "../src/db/activities.ts";
import { brief } from "../src/mcp/tools/activities.ts";

const enc = (d: unknown) => new TextEncoder().encode(JSON.stringify(d));

Deno.test("summary v2: moving time excludes standing, pace by moving, weather, elevation, laps", () => {
  // 40 min recording, first 10 min standing at the start line, then 8 km.
  const dump = HealthKitDump.parse(
    makeDump({ minutes: 40, distanceM: 8000, segments: 4, standStartSec: 600 }),
  );
  const s = summarize(dump);
  assertEquals(s.sport, "run");
  assertEquals(s.elapsedSec, 2400);
  assertEquals(s.movingSec, 1800);
  assertEquals(s.paceSecPerKm, 225);
  assertEquals(s.paceElapsedSecPerKm, 300);
  assertEquals(s.weather?.tempC, -3.4);
  assertEquals(s.weather?.humidityPct, 88);
  assertEquals(s.elevationGainM, 42);
  assertEquals(s.running?.powerAvg, 250);
  // Cadence by moving time, like pace: the 10 min at the start line do not dilute it.
  assertEquals(s.running?.cadenceSpm, 170);
  assertEquals(s.startLocal, "08:00");
  assertEquals(s.detail, "full");
  const laps = lapsOf(dump);
  assertEquals(laps.length, 4);
  // Lap 1 (0–10 min) is all standing; lap 2 is all running: moving pace and cadence per lap.
  assertEquals(laps[0].movingSec, 0);
  assertEquals(laps[0].paceSecPerKm, null);
  assertEquals(laps[1].movingSec, 600);
  assertEquals(laps[1].paceSecPerKm, 225);
  assertEquals(laps[1].cadence, 170);
  assertEquals(laps[1].powerAvg, 250);
});

Deno.test("laps: manual markers first, km splits, mile splits dropped as duplicates", () => {
  // 40 min, 8 km at even pace; manual interval between 10 and 30 min (like a parkrun inside).
  const dump = HealthKitDump.parse(
    makeDump({ minutes: 40, distanceM: 8000, markers: [600, 1800], autoSplits: true }),
  );
  const laps = lapsOf(dump);
  const kinds = laps.map((l) => l.kind);
  assertEquals(kinds.filter((k) => k === "manual").length, 3);
  assertEquals(kinds.filter((k) => k === "split_km").length, 8);
  assertEquals(kinds.includes("split_mile"), false);
  assertEquals(kinds.slice(0, 3), ["manual", "manual", "manual"]);
  assertEquals([laps[1].startSec, laps[1].endSec, laps[1].distanceM], [600, 1800, 4000]);
  assertEquals(laps[1].paceSecPerKm, 300);
  assertEquals(laps.map((l) => l.index), laps.map((_, i) => i));
  // …and the summary carries them up front, so warm-up does not hide the effort.
  const s = summarize(dump);
  assertEquals(s.intervals?.length, 3);
  assertEquals(s.intervals?.[1].paceSecPerKm, 300);
  assertEquals(s.intervals?.[1].durationSec, 1200);
  assertEquals(summarize(HealthKitDump.parse(makeDump({}))).intervals, null);
  // Lists (list_activities, get_plan) show them in short form too.
  const row = { summary: s, durationSec: 2400, sport: "run" } as unknown as ActivityRow;
  assertEquals(brief(row).intervals?.[1], {
    startSec: 600,
    durationSec: 1200,
    distanceM: 4000,
    paceSecPerKm: 300,
    speedKmh: undefined,
    hrAvg: s.intervals?.[1].avgHr ?? undefined,
    hrMax: s.intervals?.[1].maxHr ?? undefined,
  });

  // Only mile splits (watch set to miles) → kept.
  const miles = HealthKitDump.parse(makeDump({ minutes: 40, distanceM: 8000, autoSplits: true }));
  const onlyMile = lapsOf({
    ...miles,
    workout: {
      ...miles.workout,
      events: miles.workout.events.slice(8), // drop the 8 km segments
    },
  });
  assertEquals(onlyMile.map((l) => l.kind), Array(5).fill("split_mile"));
});

Deno.test("summary: bike cadence while moving, zeros excluded; cadence stream", () => {
  const ride = HealthKitDump.parse(
    makeDump({ activityType: 13, minutes: 60, distanceM: 30000, standStartSec: 300 }),
  );
  const s = summarize(ride);
  assertEquals(s.movingSec, 3300);
  assertEquals(s.cycling?.cadenceAvg, 90);
  const run = HealthKitDump.parse(makeDump({ minutes: 40, standStartSec: 600 }));
  const st = streams(run, ["cadence"], 0, 2400, 4);
  assertEquals(st.cadence, [5, 170, 170, 170]); // the stream shows the standing part as is
});

Deno.test("summary v2: pauses without distance samples, swim lengths, mind & body, Strava copy", () => {
  const strength = summarize(
    HealthKitDump.parse(makeDump({ activityType: 20, distanceM: null, pauseSec: 60 })),
  );
  assertEquals(strength.movingSec, 2340);
  assertEquals(strength.movingBasis, "elapsed − pauses");

  // Pool: 20 lengths × 25 m, 30 s each, 30 s rest between → 10 min swimming in 20 min.
  const swim = makeDump({ activityType: 46, distanceM: null, minutes: 20 });
  swim.workout.metadata.HKSwimmingLocationType = 1;
  swim.workout.totalDistanceM = 500;
  swim.samples.distanceSwimming = {
    unit: "m",
    values: Array.from(
      { length: 20 },
      (_, i) => [i * 60, i * 60 + 30, 25] as [number, number, number],
    ),
  };
  const s = summarize(HealthKitDump.parse(swim));
  assertEquals(s.subSport, "pool");
  assertEquals(s.movingSec, 600);
  assertEquals(s.paceSecPer100m, 120);
  assertEquals(s.paceWithRestsSecPer100m, 240);

  const mind = summarize(
    HealthKitDump.parse(makeDump({ activityType: 29, distanceM: null, minutes: 10 })),
  );
  assertEquals(mind.kind, "recovery");
  assertEquals(mind.subSport, "mind_and_body");

  const strava = makeDump({
    activityType: 13,
    indoor: true,
    sourceName: "Strava",
    bundleId: "com.strava.stravaride",
  });
  strava.samples = {};
  strava.route = [];
  const ss = summarize(HealthKitDump.parse(strava));
  assertEquals(ss.detail, "summary_only");
  assertEquals(ss.distanceKind, "virtual");
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

    // get_plan shows what was actually done each day, matched or not.
    const day = (await h.call("get_plan", { from: "2026-11-16", to: "2026-11-16" })).data.days[0];
    assertEquals(day.activities.length, 2); // run + watch ride (Strava copy hidden)
    assertEquals(day.activities[0].startLocal, "08:00");

    // Mind & body is hidden by default; old date ranges work.
    await h.api(
      "/v1/activities/healthkit",
      enc(
        makeDump({
          start: "2026-09-03T05:00:00Z",
          activityType: 29,
          distanceM: null,
          minutes: 10,
          uuid: "MIND-1",
        }),
      ),
    );
    await h.api(
      "/v1/activities/healthkit",
      enc(makeDump({ start: "2026-09-02T05:00:00Z", uuid: "OLD-RUN" })),
    );
    const sept =
      (await h.call("list_activities", { from: "2026-09-01", to: "2026-09-30" })).data.activities;
    assertEquals(sept.map((a: { sport: string }) => a.sport), ["run"]);
    const withMind = (await h.call("list_activities", {
      from: "2026-09-01",
      to: "2026-09-30",
      includeRecovery: true,
    })).data.activities;
    assertEquals(withMind.length, 2);

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
  const raw = await Deno.readTextFile(
    new URL("../../fixtures/healthkit/contract-v1.json", import.meta.url),
  );
  const dump = HealthKitDump.parse(JSON.parse(raw));
  const s = summarize(dump);
  assertEquals(s.sport, "run");
  assertEquals(dump.workout.activities[0].location, "outdoor");
  assertEquals(lapsOf(dump).length, 2);
});

Deno.test("data migrations: outdated summaries are rebuilt from stored originals", async () => {
  const h = await mcpHarness();
  try {
    const res =
      await (await h.api("/v1/activities/healthkit", enc(makeDump({ uuid: "OLD-SUMMARY" }))))
        .json();
    await h.db
      .sql`update zone2.activities set summary = summary - 'v' || '{"legacy": true}' where id = ${res.activityId}`;
    const denied = await h.app.request("/jobs/data-migrations", { method: "POST" });
    assertEquals(denied.status, 404);
    const run = await h.app.request("/jobs/data-migrations", {
      method: "POST",
      headers: { "x-zone2-job-secret": "j".repeat(40) },
    });
    const out = await run.json();
    assertEquals(out.processed, 1);
    assertEquals(out.remaining, 0);
    assertEquals(out.migrations[0].name, `activity-summaries-v${SUMMARY_VERSION}`);
    // Idempotent: a second call has nothing to do.
    const again = await (await h.app.request("/jobs/data-migrations", {
      method: "POST",
      headers: { "x-zone2-job-secret": "j".repeat(40) },
    })).json();
    assertEquals(again.processed, 0);
    const [row] = await h.db.sql`select summary from zone2.activities where id = ${res.activityId}`;
    assertEquals(row.summary.v, SUMMARY_VERSION);
    assertEquals(row.summary.legacy, undefined);
  } finally {
    await h.drop();
  }
});
