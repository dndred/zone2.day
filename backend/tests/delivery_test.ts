// Watch delivery: device reports → delivery state in get_plan / get_planned_workout /
// get_delivery_status; outdated versions; device problems; user isolation.
import { assert, assertEquals } from "@std/assert";
import { randomToken, sha256 } from "../src/auth/crypto.ts";
import { mcpHarness } from "./helpers/mcp.ts";

Deno.test("delivery: reports, states, outdated, removed, problems, isolation", async () => {
  const h = await mcpHarness({ now: "2026-11-15T03:00:00Z" });
  try {
    await h.call("update_profile", { patch: { timezone: "Asia/Barnaul" }, why: "пояс атлета" });
    const planned = await h.call("plan_workouts", {
      items: [
        { date: "2026-11-16", sport: "run", title: "Easy" },
        { date: "2026-11-17", sport: "run", title: "Tempo" },
        { date: "2026-11-16", sport: "strength", title: "Gym", execution: "none" },
      ],
      why: "неделя",
    });
    assert(!planned.isError, JSON.stringify(planned.data));
    const [easy, tempo, gym] = planned.data.created.map((c: { id: string }) => c.id);
    const report = (items: unknown[], error: string | null = null) =>
      h.api(
        "/v1/deliveries",
        JSON.stringify({
          deviceId: "device-0001",
          deviceName: "iPhone",
          appVersion: "0.1.0",
          lastPullAt: "2026-11-15T02:59:00Z",
          watch: { error, items },
        }),
      );

    let r = await report([{
      plannedWorkoutId: easy,
      version: 1,
      date: "2026-11-16",
      warnings: ["step x: no alert"],
    }]);
    assertEquals(r.status, 200);
    assertEquals(await r.json(), { onWatch: 1, removed: 0 });

    const plan = async () => {
      const p = (await h.call("get_plan", { from: "2026-11-16", to: "2026-11-17" })).data;
      // deno-lint-ignore no-explicit-any
      const all = p.days.flatMap((d: any) => d.workouts);
      // deno-lint-ignore no-explicit-any
      return (id: string) => all.find((w: any) => w.id === id).delivery;
    };
    let d = await plan();
    assertEquals(d(easy).state, "on_watch");
    assertEquals(d(easy).device, "iPhone");
    assertEquals(d(easy).warnings, ["step x: no alert"]);
    assertEquals(d(tempo).state, "not_on_watch");
    assertEquals(d(gym), undefined); // not a watch workout

    // The coach edits the workout → the watch has an older version until the phone syncs.
    await h.call("update_planned_workout", {
      id: easy,
      patch: { title: "Easy 45" },
      why: "чуть дольше",
    });
    d = await plan();
    assertEquals(d(easy).state, "outdated");
    const one = (await h.call("get_planned_workout", { id: easy })).data;
    assertEquals(one.delivery.state, "outdated");

    // Next report: new version of easy, tempo added.
    r = await report([
      { plannedWorkoutId: easy, version: 2, date: "2026-11-16" },
      { plannedWorkoutId: tempo, version: 1, date: "2026-11-17" },
    ]);
    d = await plan();
    assertEquals([d(easy).state, d(tempo).state], ["on_watch", "on_watch"]);

    // Workout removed from the watch (e.g. deleted from plan or done) → removed.
    r = await report([{ plannedWorkoutId: tempo, version: 1, date: "2026-11-17" }]);
    assertEquals(await r.json(), { onWatch: 1, removed: 1 });
    d = await plan();
    assertEquals(d(easy).state, "not_on_watch");

    // Device-level problem is surfaced.
    await report([], "not authorized");
    const status = (await h.call("get_delivery_status", {})).data;
    // deno-lint-ignore no-explicit-any
    const byId = (id: string) => status.workouts.find((w: any) => w.id === id);
    assertEquals(byId(easy).delivery, { state: "not_on_watch", problem: "not authorized" });
    assertEquals(byId(gym).delivery.state, "not_applicable");
    assertEquals(status.devices[0].watchError, "not authorized");
    assertEquals(status.devices[0].lastPullAt, "2026-11-15T02:59:00.000Z");

    // Bad body; MCP token cannot report.
    assertEquals((await h.api("/v1/deliveries", JSON.stringify({ deviceId: "x" }))).status, 400);
    const viaMcpToken = await h.app.request("/v1/deliveries", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${h.token}` },
      body: JSON.stringify({ deviceId: "device-0001", watch: { items: [] } }),
    });
    assertEquals(viaMcpToken.status, 401);

    // Isolation: another user's report with our workout id does not touch our deliveries.
    const other = crypto.randomUUID();
    const otherToken = randomToken("z2a");
    await h.db.sql`insert into zone2.users (id, display_name) values (${other}, 'B')`;
    await h.db
      .sql`insert into zone2.oauth_tokens (token_hash, kind, client_id, user_id, scopes, resource, family_id, expires_at)
      values (${await sha256(otherToken)}, 'access', 'zone2-ios', ${other}, ${["app"]}, null,
              ${crypto.randomUUID()}, now() + interval '3650 days')`;
    const foreign = await h.app.request("/v1/deliveries", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${otherToken}` },
      body: JSON.stringify({
        deviceId: "device-0001",
        deviceName: "Other",
        watch: { items: [{ plannedWorkoutId: easy, version: 2, date: "2026-11-16" }] },
      }),
    });
    assertEquals(foreign.status, 200);
    d = await plan();
    assertEquals(d(easy).state, "not_on_watch");
    const devices = (await h.call("get_delivery_status", {})).data.devices;
    assertEquals(devices.map((x: { name: string }) => x.name), ["iPhone"]);
  } finally {
    await h.drop();
  }
});
