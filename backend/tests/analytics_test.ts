// Analytics: per-activity analysis (GAP, histograms, steady segments, decoupling), zones,
// and the MCP tools get_load / get_zone_distribution / get_efficiency_trend / get_activity.
import { assert, assertAlmostEquals, assertEquals } from "@std/assert";
import { analyze, minettiCost } from "../src/domain/analysis.ts";
import type { Profile } from "../src/domain/entities.ts";
import { HealthKitDump, summarize } from "../src/domain/healthkit.ts";
import {
  distribute,
  edwardsTrimp,
  hrZones,
  observedMaxHr,
  powerZones,
  zoneRanges,
} from "../src/domain/zones.ts";
import { randomToken, sha256 } from "../src/auth/crypto.ts";
import { gzip } from "../src/ingest/healthkit.ts";
import { makeDump } from "./helpers/dump.ts";
import { mcpHarness } from "./helpers/mcp.ts";

type S = [number, number, number];

/** A run with HR(t), speed(t) m/s and altitude(t); samples like the watch (HR 5 s, distance 2.6 s). */
function shaped(o: {
  minutes: number;
  hr: (t: number) => number;
  speed: (t: number) => number;
  alt?: (t: number) => number;
  start?: string;
  uuid?: string;
}) {
  const d = makeDump({ minutes: o.minutes, start: o.start, uuid: o.uuid });
  const n = o.minutes * 60;
  const hr: S[] = [];
  for (let t = 0; t < n; t += 5) hr.push([t, t, o.hr(t)]);
  const dist: S[] = [];
  let total = 0;
  for (let t = 0; t + 2.6 <= n; t += 2.6) {
    const v = o.speed(t) * 2.6;
    total += v;
    dist.push([t, t + 2.6, v]);
  }
  d.samples.heartRate = { unit: "count/min", values: hr };
  d.samples.distanceWalkingRunning = { unit: "m", values: dist };
  d.workout.totalDistanceM = total;
  d.route = Array.from(
    { length: n },
    (_, t) => [t, 53.35, 83.76, o.alt ? o.alt(t) : 150, 5, 3, 3, 90],
  );
  return d;
}

const input = (d: HealthKitDump) => ({
  sport: "run",
  subSport: null,
  moving: [[0, d.workout.durationSec]] as [number, number][],
  distanceKey: "distanceWalkingRunning",
});

Deno.test("analysis: flat steady run — GAP = pace, one steady segment, HR histogram", () => {
  const d = HealthKitDump.parse(shaped({ minutes: 60, hr: () => 140, speed: () => 3 }));
  const a = analyze(d, input(d));
  assertAlmostEquals(a.gapSecPerKm!, 333, 2); // 1000 / 3
  assertEquals(a.hrHist!.sec.reduce((x, y) => x + y, 0), 3600);
  assertEquals(a.hrHist!.lo, 140);
  assertEquals(a.steady.length, 1);
  assertEquals(a.steady[0].startSec, 120); // first 2 min dropped
  assertEquals(a.steady[0].durationSec, 3480);
  assertAlmostEquals(a.steady[0].speed!, 3, 0.01);
  assertAlmostEquals(a.decoupling!.pct, 0, 0.5);
});

Deno.test("analysis: uphill makes GAP faster than pace; Minetti cost", () => {
  assertAlmostEquals(minettiCost(0), 3.6, 1e-9);
  assert(minettiCost(0.1) > minettiCost(0) && minettiCost(-0.1) < minettiCost(0));
  // 5 % climb at 2.5 m/s: altitude rises 0.125 m/s.
  const d = HealthKitDump.parse(
    shaped({ minutes: 30, hr: () => 145, speed: () => 2.5, alt: (t) => 100 + 0.125 * t }),
  );
  const a = analyze(d, input(d));
  const pace = 1000 / 2.5;
  assert(a.gapSecPerKm! < pace - 30, `gap ${a.gapSecPerKm} vs pace ${pace}`);
  assertAlmostEquals(a.steady[0].gradePct!, 5, 0.5);
});

Deno.test("analysis: HR drifting up at the same pace → positive decoupling", () => {
  // 80 min at 3 m/s; HR 140 → 154 linearly (≈10 % drift).
  const d = HealthKitDump.parse(
    shaped({ minutes: 80, hr: (t) => 140 + 14 * t / 4800, speed: () => 3 }),
  );
  const a = analyze(d, input(d));
  assert(a.decoupling, "decoupling expected");
  assert(a.decoupling.pct > 3 && a.decoupling.pct < 8, `pct ${a.decoupling.pct}`);
  assertEquals(a.decoupling.metric, "pace");
});

Deno.test("analysis: intervals and stops break steady segments; short runs have no decoupling", () => {
  // 40 min: 10 min easy, 5 × (2 min hard, 2 min stop), 10 min easy.
  const hard = (t: number) => t >= 600 && t < 1800 && Math.floor((t - 600) / 120) % 2 === 0;
  const stop = (t: number) => t >= 600 && t < 1800 && !hard(t);
  const d = HealthKitDump.parse(shaped({
    minutes: 40,
    hr: (t) => (hard(t) ? 170 : 140),
    speed: (t) => (hard(t) ? 4.5 : stop(t) ? 0 : 3),
  }));
  const moving = summarize(d);
  const a = moving.analysis;
  assertEquals(a.decoupling, null);
  for (const g of a.steady) assert(g.startSec + g.durationSec <= 600 || g.startSec >= 1800);
  // Histogram counts moving time only (stops excluded).
  assertAlmostEquals(a.hrHist!.sec.reduce((x, y) => x + y, 0), moving.movingSec, 5);
});

Deno.test("zones: custom, Friel, max HR, observed; Coggan; distribute; TRIMP", () => {
  const base = {
    timezone: "UTC",
    travel: [],
    locale: "ru",
    run: {},
    bike: {},
    swim: {},
    zoneModel: {},
    equipment: {},
  };
  const p = (x: Partial<Profile>) => ({ ...base, ...x }) as Profile;
  const friel = hrZones(p({ run: { lthr: 170 } }), "run")!;
  assertEquals(friel.bounds, [145, 153, 162, 170]);
  assertEquals(zoneRanges(friel), ["<145", "145–152", "153–161", "162–169", "≥170"]);
  // Bike without its own LTHR borrows the run one (run percentages).
  assertEquals(hrZones(p({ run: { lthr: 170 } }), "bike")!.basis.includes("run.lthr"), true);
  assertEquals(hrZones(p({ run: { hrZones: [160, 130, 145] } }), "run")!.bounds, [130, 145, 160]);
  assertEquals(hrZones(p({ run: { maxHr: 190 } }), "run")!.bounds, [114, 133, 152, 171]);
  assertEquals(hrZones(p({}), "run"), null);
  const obs = hrZones(p({}), "run", observedMaxHr([150, 185, 230, 181, 170, 179, 160]))!;
  assertEquals(obs.confidence, "low");
  assertEquals(obs.bounds, [107, 125, 143, 161]); // 3rd highest valid max = 179
  assertEquals(observedMaxHr([180, 181]), null);
  const cog = powerZones(p({ bike: { ftp: 200 } }), "bike")!;
  assertEquals(cog.bounds, [112, 152, 182, 212, 242, 302]);
  assertEquals(powerZones(p({ bike: { ftp: 200 } }), "run"), null);
  const sec = distribute({ lo: 140, step: 1, sec: [60, 60, 0, 0, 0, 120] }, friel);
  assertEquals(sec, [120, 120, 0, 0, 0]); // 140…144 bpm → Z1, 145 → Z2
  assertEquals(edwardsTrimp([600, 600, 0, 0, 0]), 30);
});

Deno.test("analytics tools: load, zones, efficiency trend, activity view", async () => {
  const h = await mcpHarness({ now: "2026-11-30T10:00:00Z" });
  const post = async (d: unknown) => {
    const r = await h.api(
      "/v1/activities/healthkit",
      await gzip(new TextEncoder().encode(JSON.stringify(d))),
      "application/gzip",
    );
    assert(r.status === 201 || r.status === 200, String(r.status));
    return (await r.json()).activityId as string;
  };
  try {
    await h.call("update_profile", { patch: { run: { lthr: 170 } }, why: "порог из теста" });
    // Six weekly easy runs, 60 min at HR 140, getting faster: 2.80 → 3.05 m/s.
    const ids: string[] = [];
    for (let w = 0; w < 6; w++) {
      const day = 2 + w * 4; // 2, 6, 10, … Nov (UTC 01:00 → same day in Barnaul)
      ids.push(
        await post(shaped({
          minutes: 60,
          hr: () => 140,
          speed: () => 2.8 + w * 0.05,
          start: `2026-11-${String(day).padStart(2, "0")}T01:00:00Z`,
          uuid: `EASY-${w}`,
        })),
      );
    }
    // One hard run (HR 165) on 25 Nov.
    await post(
      shaped({
        minutes: 30,
        hr: () => 165,
        speed: () => 3.8,
        start: "2026-11-25T01:00:00Z",
        uuid: "HARD",
      }),
    );

    const load = (await h.call("get_load", {})).data;
    assert(!load.error, JSON.stringify(load));
    const total = load.periods.reduce(
      (a: number, p: { totals: { sessions: number } }) => a + p.totals.sessions,
      0,
    );
    assertEquals(total, 7);
    const withHr = load.periods.filter((p: { hrLoad: number | null }) => p.hrLoad !== null);
    assert(withHr.length > 0);
    assert(load.hrLoadBasis[0].includes("Friel"));

    const zones = (await h.call("get_zone_distribution", {
      from: "2026-11-01",
      to: "2026-11-30",
      groupBy: "total",
    })).data;
    assert(!zones.error, JSON.stringify(zones));
    assertEquals(zones.zones.run.ranges[0], "<145");
    // 6 h easy (Z1) vs 30 min at 165 (Z4): ~92 % low.
    assert(zones.total.polarization.lowPct > 85, JSON.stringify(zones.total));
    assert(zones.total.zones[3].sec > 1500);
    assertEquals(zones.weeks, undefined);

    // Default corridor = Friel Z2 (145–152): easy runs at 140 are outside → explicit corridor.
    const none =
      (await h.call("get_efficiency_trend", { sport: "run", metric: "pace_at_hr" })).data;
    assertEquals(none.points.length, 0);
    const eff = (await h.call("get_efficiency_trend", {
      sport: "run",
      metric: "pace_at_hr",
      hrLow: 135,
      hrHigh: 145,
      from: "2026-11-01",
    })).data;
    assertEquals(eff.points.length, 6);
    assert(eff.trend.secPerKmPer4Weeks < -10, JSON.stringify(eff.trend)); // getting faster
    assertEquals(eff.points[0].gradeAdjusted, true);
    const bad = await h.call("get_efficiency_trend", { sport: "bike", metric: "pace_at_hr" });
    assert(bad.isError);

    const act = (await h.call("get_activity", { id: ids[5] })).data;
    assertEquals(act.activity.summary.analysis, undefined); // raw histograms are not shown
    assertAlmostEquals(act.activity.analysis.zones.hr.sec[0], 3600, 5);
    assert(act.activity.analysis.decoupling.pct < 1);
    assert(act.activity.gapSecPerKm > 0);

    // The app feed carries only GAP, decoupling and the HR load (no histograms or segments).
    const feed = await (await h.app.request("/v1/sync", {
      headers: { authorization: `Bearer ${h.appToken}` },
    })).json();
    const a = feed.changes.find((c: { entity: string; id: string }) =>
      c.entity === "activity" && c.id === ids[5]
    );
    assertEquals(Object.keys(a.data.summary.analysis).sort(), [
      "decoupling",
      "gapSecPerKm",
      "trimp",
    ]);

    // Isolation: another athlete sees none of this.
    const other = crypto.randomUUID();
    const otherToken = randomToken("z2a");
    await h.db.sql`insert into zone2.users (id, display_name) values (${other}, 'B')`;
    await h.db
      .sql`insert into zone2.oauth_tokens (token_hash, kind, client_id, user_id, scopes, resource, family_id, expires_at)
      values (${await sha256(otherToken)}, 'access', 'test-client', ${other}, ${["mcp"]}, null,
              ${crypto.randomUUID()}, now() + interval '3650 days')`;
    const as = async (tool: string, args: Record<string, unknown>) => {
      const res = await h.app.request("/mcp", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          accept: "application/json, text/event-stream",
          "mcp-protocol-version": "2025-06-18",
          authorization: `Bearer ${otherToken}`,
        },
        body: JSON.stringify({
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: { name: tool, arguments: args },
        }),
      });
      return JSON.parse((await res.json()).result.content[0].text);
    };
    const theirLoad = await as("get_load", { from: "2026-11-01", to: "2026-11-30" });
    assertEquals(
      theirLoad.periods.reduce(
        (a: number, p: { totals: { sessions: number } }) => a + p.totals.sessions,
        0,
      ),
      0,
    );
    const theirZones = await as("get_zone_distribution", { from: "2026-11-01", to: "2026-11-30" });
    assertEquals(theirZones.error, "no_zones"); // no profile, no activities of their own
    const theirEff = await as("get_efficiency_trend", {
      sport: "run",
      metric: "pace_at_hr",
      hrLow: 135,
      hrHigh: 145,
      from: "2026-11-01",
    });
    assertEquals(theirEff.points, []);
  } finally {
    await h.drop();
  }
});
