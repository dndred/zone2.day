import { assert, assertAlmostEquals, assertEquals, assertStringIncludes } from "@std/assert";
import { fitToDump, InvalidFitError } from "../src/domain/fit.ts";
import { lapsOf, summarize } from "../src/domain/healthkit.ts";
import { b64, makeFit } from "./helpers/fit.ts";
import { makeDump } from "./helpers/dump.ts";
import { BASE, mcpHarness } from "./helpers/mcp.ts";

const enc = (d: unknown) => new TextEncoder().encode(JSON.stringify(d));

Deno.test("FIT → dump: MyWhoosh-like ride summarizes like a Health workout", () => {
  const dump = fitToDump(makeFit({ minutes: 60, laps: 3 }), "sha256:x", new Date());
  const s = summarize(dump);
  assertEquals(s.sport, "bike");
  assertEquals(s.subSport, "indoor_bike");
  assertEquals(s.elapsedSec, 3600);
  assertEquals(s.distanceKind, "virtual");
  assertAlmostEquals(s.distanceM!, 32400, 1);
  assertEquals(s.cycling?.powerAvg, 200);
  assertEquals(s.cycling?.cadenceAvg, 90);
  assert(s.hr && s.hr.avg! > 135 && s.hr.avg! < 145);
  assertEquals(s.detail, "full");
  assertEquals(s.sourceApp, "MyWhoosh");
  const laps = lapsOf(dump);
  assertEquals(laps.length, 3);
  assertEquals(laps[0].durationSec, 1200);
  assertEquals(laps[1].powerAvg, 200);
});

Deno.test("FIT → dump: rejects non-FIT and damaged files", () => {
  let err: unknown;
  try {
    fitToDump(new TextEncoder().encode("<workout_file/>"), "x", new Date());
  } catch (e) {
    err = e;
  }
  assert(err instanceof InvalidFitError);
  const broken = makeFit();
  broken[broken.length - 1] ^= 0xff; // CRC
  err = undefined;
  try {
    fitToDump(broken, "x", new Date());
  } catch (e) {
    err = e;
  }
  assert(err instanceof InvalidFitError);
});

Deno.test("import FIT via upload link: page, import, plan, Strava copy, streams, idempotent", async () => {
  const h = await mcpHarness({ now: "2026-11-17T03:00:00Z" });
  try {
    await h.call("update_profile", { patch: { timezone: "Asia/Barnaul" }, why: "пояс" });
    const planned = await h.call("plan_workouts", {
      items: [{ date: "2026-11-16", sport: "bike", subSport: "indoor_bike", title: "Станок 60" }],
      why: "план",
    });
    const bikeId = planned.data.created[0].id;
    // Strava's copy of the ride already came through Apple Health and took the plan.
    const strava = await (await h.api(
      "/v1/activities/healthkit",
      enc(makeDump({
        start: "2026-11-16T12:00:30Z",
        activityType: 13,
        indoor: true,
        minutes: 59,
        uuid: "RIDE-S",
        sourceName: "Strava",
        bundleId: "com.strava.stravaride",
      })),
    )).json();
    assertEquals(strava.plannedWorkoutId, bikeId);

    // Not uploaded yet → helpful error.
    const link = (await h.call("create_upload_link")).data;
    assert(link.url.startsWith(`${BASE}/u/`));
    const early = await h.call("import_activity_file", { uploadId: link.uploadId });
    assertEquals(early.data.error, "not_uploaded");

    // The athlete opens the page and uploads the file.
    const path = new URL(link.url).pathname;
    const pageRes = await h.app.request(path, { headers: { "accept-language": "ru" } });
    assertEquals(pageRes.status, 200);
    assertStringIncludes(await pageRes.text(), "Загрузить");
    const bad = new FormData();
    bad.append("file", new File([new TextEncoder().encode("not a fit file")], "ride.zwo"));
    assertEquals((await h.app.request(path, { method: "POST", body: bad })).status, 422);
    const fit = makeFit({ start: "2026-11-16T12:00:00Z" });
    const form = new FormData();
    form.append("file", new File([fit as BlobPart], "MyWhoosh_ride.fit"));
    const up = await h.app.request(path, { method: "POST", body: form });
    assertEquals(up.status, 200);
    // Single use.
    assertEquals((await h.app.request(path)).status, 410);

    const imp = await h.call("import_activity_file", {
      uploadId: link.uploadId,
      title: "Станок: 3×20",
      rpe: 6,
      why: "Выгрузка MyWhoosh",
    });
    assert(!imp.isError, JSON.stringify(imp.data));
    const id = imp.data.activity.id;
    assertEquals(imp.data.created, true);
    assertEquals(imp.data.activity.title, "Станок: 3×20");
    assertEquals(imp.data.activity.date, "2026-11-16");
    assertEquals(imp.data.activity.source, "MyWhoosh");
    assertEquals(imp.data.plan.id, bikeId);
    assertEquals(imp.data.replacedDuplicates[0].id, strava.activityId);
    assert(imp.data.changeId);

    // Lists show the FIT ride only; the plan is done by it.
    const list = (await h.call("list_activities", {})).data.activities;
    assertEquals(list.map((a: { id: string }) => a.id), [id]);
    const plan = (await h.call("get_plan", { from: "2026-11-16", to: "2026-11-16" })).data;
    assertEquals(plan.days[0].workouts[0].status, "done");
    assertEquals(plan.days[0].workouts[0].activity.id, id);

    // Full summary, laps, original file, streams decoded from the FIT.
    const act = (await h.call("get_activity", { id })).data;
    assertEquals(act.activity.summary.cycling.powerAvg, 200);
    assertEquals(act.activity.rpe, 6);
    assertEquals(act.files[0].kind, "fit_original");
    assertEquals(act.activity.laps.length, 3);
    const st = (await h.call("get_activity_streams", {
      id,
      channels: ["cyclingPower", "heartRate", "cadence"],
      maxPoints: 60,
    })).data;
    assertEquals(st.columns.t.length, 60);
    assertAlmostEquals(st.columns.cyclingPower[10], 200, 1);
    assertEquals(st.columns.cadence[5], 90);
    // The app's streams endpoint works for FIT rides too.
    const appSt = await h.app.request(`/v1/activities/${id}/streams`, {
      headers: { authorization: `Bearer ${h.appToken}` },
    });
    assertEquals(appSt.status, 200);

    // Same file again (base64, e.g. from Claude Code) → same activity.
    const again = await h.call("import_activity_file", { fileBase64: b64(fit) });
    assert(!again.isError, JSON.stringify(again.data));
    assertEquals(again.data.activity.id, id);
    assertEquals(again.data.created, false);
    assertEquals(again.data.activity.title, "Станок: 3×20");

    // Wrong input.
    assertEquals(
      (await h.call("import_activity_file", { fileBase64: b64(new Uint8Array(64)) })).data.error,
      "invalid_file",
    );
    assertEquals((await h.call("import_activity_file", {})).data.error, "bad_input");
  } finally {
    await h.drop();
  }
});

Deno.test("import FIT: explicit plannedWorkoutId, conflict is checked before writing", async () => {
  const h = await mcpHarness({ now: "2026-11-17T03:00:00Z" });
  try {
    await h.call("update_profile", { patch: { timezone: "Asia/Barnaul" }, why: "пояс" });
    const planned = await h.call("plan_workouts", {
      items: [
        { date: "2026-11-15", sport: "bike", title: "Перенесённый станок" },
        { date: "2026-11-16", sport: "bike", title: "Станок" },
      ],
      why: "план",
    });
    const [movedId, dayId] = planned.data.created.map((c: { id: string }) => c.id);
    const imp = await h.call("import_activity_file", {
      fileBase64: b64(makeFit({ start: "2026-11-16T12:00:00Z" })),
      plannedWorkoutId: movedId,
    });
    assert(!imp.isError, JSON.stringify(imp.data));
    assertEquals(imp.data.plan.id, movedId);
    assertEquals(imp.data.warnings.length, 1); // done on the 16th, planned on the 15th

    // A second file for the same planned workout → conflict, nothing created.
    const other = await h.call("import_activity_file", {
      fileBase64: b64(makeFit({ start: "2026-11-16T15:00:00Z", minutes: 30 })),
      plannedWorkoutId: movedId,
    });
    assertEquals(other.data.error, "conflict");
    assertEquals((await h.call("list_activities", {})).data.activities.length, 1);
    const plan = (await h.call("get_plan", { from: "2026-11-16", to: "2026-11-16" })).data;
    assertEquals(
      plan.days[0].workouts.find((w: { id: string }) => w.id === dayId).status,
      "missed",
    );
  } finally {
    await h.drop();
  }
});

Deno.test("create_activity: manual entry in the athlete's zone, plan match, validation", async () => {
  const h = await mcpHarness({ now: "2026-11-17T03:00:00Z" });
  try {
    await h.call("update_profile", { patch: { timezone: "Asia/Barnaul" }, why: "пояс" });
    const planned = await h.call("plan_workouts", {
      items: [{ date: "2026-11-16", sport: "run", title: "Лёгкий 8 км" }],
      why: "план",
    });
    const runId = planned.data.created[0].id;
    const res = await h.call("create_activity", {
      sport: "run",
      subSport: "treadmill",
      start: "2026-11-16T07:30",
      durationSec: 2700,
      movingSec: 2640,
      distanceM: 8000,
      hrAvg: 142,
      title: "Дорожка в зале",
      athleteNotes: "Часы забыл, цифры с дорожки",
      rpe: 4,
      why: "Атлет рассказал",
    });
    assert(!res.isError, JSON.stringify(res.data));
    const a = res.data.activity;
    assertEquals(a.date, "2026-11-16");
    assertEquals(a.startLocal, "07:30");
    assertEquals(a.paceSecPerKm, 330);
    assertEquals(a.hrAvg, 142);
    assertEquals(a.source, "manual");
    assertEquals(a.distanceKind, "virtual");
    assertEquals(res.data.plan.id, runId);
    const act = (await h.call("get_activity", { id: a.id })).data;
    assertEquals(act.activity.athleteNotes, "Часы забыл, цифры с дорожки");
    assertEquals(act.activity.summary.detail, "manual");
    assertEquals(
      (await h.call("get_activity_streams", { id: a.id })).data.error,
      "no_streams",
    );

    // Same time again → overlap warning (it may already be recorded).
    const dup = await h.call("create_activity", {
      sport: "run",
      start: "2026-11-16T00:40:00Z",
      durationSec: 1800,
      why: "повтор",
    });
    assertEquals(dup.data.warnings.length, 1);
    assertStringIncludes(dup.data.warnings[0], a.id);

    // Validation.
    const future = await h.call("create_activity", {
      sport: "run",
      start: "2026-11-20T08:00",
      durationSec: 1800,
      why: "будущее",
    });
    assertEquals(future.data.error, "bad_input");
    const hr = await h.call("create_activity", {
      sport: "run",
      start: "2026-11-15T08:00",
      durationSec: 1800,
      hrAvg: 170,
      hrMax: 150,
      why: "ошибка",
    });
    assertEquals(hr.data.error, "bad_input");
  } finally {
    await h.drop();
  }
});

Deno.test("activity input: users are isolated", async () => {
  const a = await mcpHarness({ now: "2026-11-17T03:00:00Z" });
  try {
    const link = (await a.call("create_upload_link")).data;
    const form = new FormData();
    form.append("file", new File([makeFit() as BlobPart], "ride.fit"));
    await a.app.request(new URL(link.url).pathname, { method: "POST", body: form });
    const planned = await a.call("plan_workouts", {
      items: [{ date: "2026-11-16", sport: "bike", title: "Чужой" }],
      why: "тест изоляции",
    });
    const plannedId = planned.data.created[0].id;

    const other = crypto.randomUUID();
    const { randomToken, sha256 } = await import("../src/auth/crypto.ts");
    const token = randomToken("z2a");
    await a.db.sql`insert into zone2.users (id, display_name) values (${other}, 'B')`;
    await a.db
      .sql`insert into zone2.oauth_tokens (token_hash, kind, client_id, user_id, scopes, resource, family_id, expires_at)
      values (${await sha256(token)}, 'access', 'test-client', ${other}, ${[
      "mcp",
    ]}, ${`${BASE}/mcp`}, ${crypto.randomUUID()}, now() + interval '3650 days')`;
    const callB = async (name: string, args: unknown) => {
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
          params: { name, arguments: args },
        }),
      });
      return JSON.parse((await res.json()).result.content[0].text);
    };
    // B cannot import A's upload, nor attach anything to A's planned workout.
    assertEquals(
      (await callB("import_activity_file", { uploadId: link.uploadId })).error,
      "not_found",
    );
    assertEquals(
      (await callB("import_activity_file", {
        fileBase64: b64(makeFit()),
        plannedWorkoutId: plannedId,
      }))
        .error,
      "not_found",
    );
    assertEquals(
      (await callB("create_activity", {
        sport: "bike",
        start: "2026-11-16T10:00:00Z",
        durationSec: 3600,
        plannedWorkoutId: plannedId,
        why: "чужое",
      })).error,
      "not_found",
    );
    // The same FIT imported by B is B's own activity, invisible to A.
    const own = await callB("import_activity_file", { fileBase64: b64(makeFit()) });
    assertEquals(own.created, true);
    assertEquals((await a.call("list_activities", {})).data.activities.length, 0);
  } finally {
    await a.drop();
  }
});

Deno.test("real MyWhoosh FIT (fixtures/fit): numbers match the file's own session", async () => {
  const bytes = await Deno.readFile(
    new URL("../../fixtures/fit/mywhoosh-2026-11-13.fit", import.meta.url),
  );
  const dump = fitToDump(bytes, "sha256:fixture", new Date());
  const s = summarize(dump);
  assertEquals([s.sport, s.subSport, s.sourceApp], ["bike", "indoor_bike", "MyWhoosh"]);
  assertEquals(s.elapsedSec, 3730);
  assertEquals(s.distanceM, 17138.7);
  assertEquals(s.distanceKind, "virtual");
  // Session: avgPower 140, maxPower 232, maxHR 139, 524 kcal, ascent 330 m.
  assertEquals(s.cycling?.powerAvg, 140);
  assertEquals(s.cycling?.powerMax, 232);
  assertEquals(s.hr?.max, 139);
  assertAlmostEquals(s.hr!.avg!, 119, 1);
  assertEquals(s.energyKcal, 524);
  assertEquals(s.elevationGainM, 330);
  // 105 s standing before the start + 29 s stop: not moving (virtual speed < 1 m/s).
  assertAlmostEquals(s.movingSec, 3593, 15);
  assertEquals(s.speedKmh, 17.2);
  // Coasting zeros excluded (the file's own avgCadence 84 includes them).
  assertAlmostEquals(s.cycling!.cadenceAvg!, 89, 1);
  // Virtual-world coordinates are dropped; one session lap → no segments.
  assertEquals(dump.route.length, 0);
  assertEquals(lapsOf(dump).length, 0);
});
