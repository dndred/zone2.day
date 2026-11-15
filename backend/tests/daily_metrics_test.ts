// Daily health metrics: phone upload (replace by day), baselines and flags, MCP get_daily_metrics,
// recovery in get_context, isolation.
import { assert, assertEquals } from "@std/assert";
import { randomToken, sha256 } from "../src/auth/crypto.ts";
import { compareDays, type DailyMetrics } from "../src/domain/readiness.ts";
import { addDays } from "../src/domain/time.ts";
import { mcpHarness } from "./helpers/mcp.ts";

/** 30 calm days ending the day before `end`, with a little day-to-day noise. */
function history(end: string, days = 30): DailyMetrics[] {
  return Array.from({ length: days }, (_, i) => {
    const wiggle = (i % 3) - 1; // −1, 0, +1
    return {
      date: addDays(end, -(days - i)),
      restingHr: 48 + wiggle,
      hrvSdnnMs: 60 + 4 * wiggle,
      hrvSamples: 6,
      sleep: { asleepMin: 450 + 10 * wiggle, deepMin: 60, remMin: 100, coreMin: 290, awakeMin: 20 },
      respiratoryRate: 14 + 0.2 * wiggle,
      wristTempC: 34.6 + 0.05 * wiggle,
      weightKg: 72,
      vo2max: 52,
    };
  });
}

Deno.test("readiness: baseline needs 14 days; flags on a bad morning", () => {
  const calm = history("2026-11-30");
  const sick: DailyMetrics = {
    date: "2026-11-30",
    restingHr: 56,
    hrvSdnnMs: 38,
    hrvSamples: 5,
    sleep: { asleepMin: 320 },
    respiratoryRate: 16,
    wristTempC: 35.3,
    weightKg: 71.5,
    vo2max: 52,
  };
  const [day] = compareDays([...calm, sick], "2026-11-30", "2026-11-30");
  assert(!("missing" in day));
  assertEquals(day.restingHr!.baseline, 48);
  assertEquals(day.restingHr!.delta, 8);
  assert(day.hrvSdnnMs!.z! <= -2);
  assertEquals(
    day.flags.sort(),
    ["hrv_very_low_today", "respiratory_rate_up", "resting_hr_up", "short_sleep", "wrist_temp_up"],
  );
  // One bad morning does not move the 7-day HRV mean below baseline − sd by itself here.
  assert(!day.flags.includes("hrv_7d_low"));
  // Too little history: no baseline, no z.
  const [early] = compareDays(history("2026-11-30", 10), "2026-11-29", "2026-11-29");
  assert(
    !("missing" in early) && early.restingHr!.baseline === null && early.restingHr!.z === null,
  );
  const [gap] = compareDays(calm, "2026-11-30", "2026-11-30");
  assertEquals(gap, { date: "2026-11-30", missing: true });
});

Deno.test("daily metrics: upload, replace, MCP view, get_context, isolation", async () => {
  const h = await mcpHarness({ now: "2026-11-30T03:00:00Z" });
  try {
    await h.call("update_profile", { patch: { timezone: "Asia/Barnaul" }, why: "часовой пояс" });
    const days = [
      ...history("2026-11-30"),
      {
        date: "2026-11-30",
        restingHr: 49,
        hrvSdnnMs: 30,
        hrvSamples: 4,
        sleep: { asleepMin: 300 },
      },
    ];
    let r = await h.api("/v1/daily-metrics", JSON.stringify({ deviceId: "dev-1", days }));
    assertEquals(r.status, 200);
    assertEquals((await r.json()).days, 31);
    // The watch synced later that morning: the phone resends the day with more data → replaced.
    r = await h.api(
      "/v1/daily-metrics",
      JSON.stringify({
        days: [{
          date: "2026-11-30",
          restingHr: 47,
          hrvSdnnMs: 62,
          hrvSamples: 7,
          sleep: { asleepMin: 470, deepMin: 70 },
          wristTempC: 34.6,
        }],
      }),
    );
    assertEquals(r.status, 200);
    const bad = await h.api(
      "/v1/daily-metrics",
      JSON.stringify({ days: [{ date: "2026-11-30", restingHr: 900 }] }),
    );
    assertEquals(bad.status, 400);

    const m = (await h.call("get_daily_metrics", { from: "2026-11-24" })).data;
    assert(!m.error, JSON.stringify(m));
    assertEquals(m.days.length, 7);
    const last = m.days[6];
    assertEquals(last.date, "2026-11-30");
    assertEquals(last.hrvSdnnMs.value, 62);
    assertEquals(last.sleep.deepMin, 70);
    assertEquals(last.respiratoryRate, null); // replaced as a whole: not sent this time
    assertEquals(last.flags, []);
    assertEquals(m.coverage.withData, 7);

    const ctx = (await h.call("get_context", {})).data;
    assertEquals(ctx.recovery.length, 3);
    assertEquals(ctx.recovery[2].hrvSdnnMs.value, 62);

    // Isolation: another athlete sees nothing of it.
    const other = crypto.randomUUID();
    const token = randomToken("z2a");
    await h.db.sql`insert into zone2.users (id, display_name) values (${other}, 'B')`;
    await h.db
      .sql`insert into zone2.oauth_tokens (token_hash, kind, client_id, user_id, scopes, resource, family_id, expires_at)
      values (${await sha256(token)}, 'access', 'test-client', ${other}, ${["mcp"]}, null,
              ${crypto.randomUUID()}, now() + interval '3650 days')`;
    const res = await h.app.request("/mcp", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        accept: "application/json, text/event-stream",
        "mcp-protocol-version": "2025-06-18",
        authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: { name: "get_daily_metrics", arguments: {} },
      }),
    });
    const theirs = JSON.parse((await res.json()).result.content[0].text);
    assertEquals(theirs.coverage.withData, 0);
    assert(theirs.notConnected);
    // The MCP token cannot write health data: it is bound to /mcp (scope mcp), the Sync API wants app.
    const write = await h.app.request("/v1/daily-metrics", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${h.token}` },
      body: JSON.stringify({ days: [] }),
    });
    assert(write.status === 401 || write.status === 403, String(write.status));
  } finally {
    await h.drop();
  }
});
