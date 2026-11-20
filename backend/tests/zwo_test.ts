// .zwo export: generator (ramps, steady, IntervalsT, free ride, errors) and export_workout over MCP.
import { assert, assertEquals, assertStringIncludes, assertThrows } from "@std/assert";
import { randomToken, sha256 } from "../src/auth/crypto.ts";
import { DEFAULT_PROFILE, type Profile } from "../src/domain/entities.ts";
import { buildZwo, ZwoError } from "../src/domain/zwo.ts";
import { exportFtp } from "../src/mcp/tools/export.ts";
import { mcpHarness } from "./helpers/mcp.ts";

const easyRide = {
  title: "Станок 60 мин — ровно & легко",
  notes: "HR ≤140",
  structure: {
    steps: [
      {
        type: "step",
        id: "wu",
        kind: "warmup",
        duration: { type: "time", sec: 600 },
        target: { metric: "power", low: 80, high: 120 },
      },
      {
        type: "step",
        id: "main",
        kind: "work",
        duration: { type: "time", sec: 2700 },
        target: { metric: "power", low: 145, high: 165 },
        secondary: [{ metric: "hr", high: 140 }, { metric: "cadence", low: 85, high: 90 }],
      },
      {
        type: "step",
        id: "cd",
        kind: "cooldown",
        duration: { type: "time", sec: 300 },
        target: { metric: "power", low: 80, high: 110 },
      },
    ],
  },
};

Deno.test("zwo: ramps for warmup/cooldown, steady middle with cadence, escaped text", () => {
  const z = buildZwo(easyRide, DEFAULT_PROFILE, 200);
  assertEquals(z.durationSec, 3600);
  assertEquals(z.warnings, []);
  assertEquals(
    z.xml,
    `<workout_file>
  <author>zone2.day</author>
  <name>Станок 60 мин — ровно &amp; легко</name>
  <description>HR ≤140</description>
  <sportType>bike</sportType>
  <tags/>
  <workout>
    <Warmup Duration="600" PowerLow="0.4" PowerHigh="0.6"/>
    <SteadyState Duration="2700" Power="0.775" Cadence="88"/>
    <Cooldown Duration="300" PowerLow="0.55" PowerHigh="0.4"/>
  </workout>
</workout_file>
`,
  );
});

Deno.test("zwo: % FTP targets, IntervalsT, free ride, expanded repeats", () => {
  const profile: Profile = { ...DEFAULT_PROFILE, bike: { ftp: 250 } };
  const z = buildZwo(
    {
      title: "VO2",
      structure: {
        steps: [
          { type: "step", id: "wu", kind: "warmup", duration: { type: "time", sec: 300 } },
          {
            type: "repeat",
            id: "r",
            count: 5,
            steps: [
              {
                type: "step",
                id: "on",
                kind: "work",
                duration: { type: "time", sec: 180 },
                target: { metric: "power", low: 110, high: 120, unit: "pct_threshold" },
              },
              {
                type: "step",
                id: "off",
                kind: "recovery",
                duration: { type: "time", sec: 120 },
                target: { metric: "power", high: 125 },
              },
            ],
          },
          {
            type: "repeat",
            id: "r2",
            count: 2,
            steps: [{
              type: "step",
              id: "s",
              kind: "work",
              duration: { type: "time", sec: 30 },
              target: { metric: "power", low: 300, high: 300 },
            }],
          },
        ],
      },
    },
    profile,
    250,
  );
  assertStringIncludes(z.xml, `<FreeRide Duration="300"/>`);
  // 110–120 % of 250 = 275–300 → 287.5 W / 250
  assertStringIncludes(
    z.xml,
    `<IntervalsT Repeat="5" OnDuration="180" OffDuration="120" OnPower="1.15" OffPower="0.5"/>`,
  );
  assertEquals(z.xml.split(`<SteadyState Duration="30" Power="1.2"/>`).length - 1, 2);
  assertEquals(z.durationSec, 300 + 5 * 300 + 60);
  assertEquals(z.warnings.length, 1); // one-sided recovery target
});

Deno.test("zwo: refuses distance steps, missing power, unresolved %", () => {
  assertThrows(
    () =>
      buildZwo(
        {
          title: "x",
          structure: {
            steps: [{
              type: "step",
              id: "a",
              kind: "work",
              duration: { type: "distance", m: 10000 },
              target: { metric: "power", low: 150, high: 160 },
            }],
          },
        },
        DEFAULT_PROFILE,
        200,
      ),
    ZwoError,
    "distance",
  );
  assertThrows(
    () =>
      buildZwo(
        {
          title: "x",
          structure: {
            steps: [{
              type: "step",
              id: "a",
              kind: "work",
              duration: { type: "time", sec: 600 },
              target: { metric: "hr", high: 140 },
            }],
          },
        },
        DEFAULT_PROFILE,
        200,
      ),
    ZwoError,
    "no power targets",
  );
  assertThrows(
    () =>
      buildZwo(
        {
          title: "x",
          structure: {
            steps: [{
              type: "step",
              id: "a",
              kind: "work",
              duration: { type: "time", sec: 600 },
              target: { metric: "power", low: 60, high: 70, unit: "pct_threshold" },
            }],
          },
        },
        DEFAULT_PROFILE,
        200,
      ),
    ZwoError,
    "no threshold",
  );
});

Deno.test("zwo: FTP choice", () => {
  assertEquals(exportFtp(DEFAULT_PROFILE), null);
  assertEquals(exportFtp(DEFAULT_PROFILE, 210)?.ftp, 210);
  assertEquals(exportFtp({ ...DEFAULT_PROFILE, bike: { ftp: { low: 220, high: 231 } } })?.ftp, 226);
  assertEquals(
    exportFtp({ ...DEFAULT_PROFILE, bike: { ftp: 230, mywhooshFtp: 215 } }),
    { ftp: 215, source: "bike.mywhooshFtp" },
  );
});

Deno.test("export_workout over MCP: needs FTP, link + xml, isolation", async () => {
  const h = await mcpHarness();
  try {
    const plan = await h.call("plan_workouts", {
      items: [{ date: "2026-11-15", sport: "bike", execution: "mywhoosh", ...easyRide }],
      why: "test",
    });
    assert(!plan.isError, JSON.stringify(plan.data));
    const id = plan.data.created?.[0]?.id ?? plan.data.items?.[0]?.id;
    assert(id, JSON.stringify(plan.data));

    const noFtp = await h.call("export_workout", { plannedWorkoutId: id });
    assert(noFtp.isError);
    assertStringIncludes(JSON.stringify(noFtp.data), "ftp_required");

    const ok = await h.call("export_workout", { plannedWorkoutId: id, ftpW: 200 });
    assert(!ok.isError, JSON.stringify(ok.data));
    assertEquals(ok.data.ftpW, 200);
    assertEquals(ok.data.filename, "2026-11-15-bike-v1.zwo");
    assertStringIncludes(ok.data.url, `${h.userId}/exports/${id}/2026-11-15-bike-v1.zwo`);
    assertStringIncludes(ok.data.url, "download=2026-11-15-bike-v1.zwo");
    assertStringIncludes(ok.data.xml, `<SteadyState Duration="2700" Power="0.775" Cadence="88"/>`);

    // Another user's token cannot export our workout.
    const other = crypto.randomUUID();
    const otherToken = randomToken("z2a");
    await h.db.sql`insert into zone2.users (id, display_name) values (${other}, 'B')`;
    await h.db
      .sql`insert into zone2.oauth_tokens (token_hash, kind, client_id, user_id, scopes, resource, family_id, expires_at)
      values (${await sha256(otherToken)}, 'access', 'test-client', ${other}, ${["mcp"]},
              ${"https://api.test.zone2.day/mcp"}, ${crypto.randomUUID()}, now() + interval '3650 days')`;
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
        params: { name: "export_workout", arguments: { plannedWorkoutId: id, ftpW: 200 } },
      }),
    });
    const body = await res.json();
    assert(body.result.isError);
    assertStringIncludes(body.result.content[0].text, "not_found");
  } finally {
    await h.drop();
  }
});
