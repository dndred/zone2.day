// Past races: status done, result, link to the race activity; unlink; user isolation.
import { assert, assertEquals } from "@std/assert";
import { randomToken, sha256 } from "../src/auth/crypto.ts";
import { BASE, mcpHarness } from "./helpers/mcp.ts";

Deno.test("upsert_event: past race with result and activity; unlink; isolation", async () => {
  const h = await mcpHarness({ now: "2026-11-17T03:00:00Z" });
  try {
    await h.call("update_profile", { patch: { timezone: "Asia/Barnaul" }, why: "пояс" });
    const act = await h.call("create_activity", {
      sport: "run",
      start: "2026-09-14T09:00",
      durationSec: 6100,
      distanceM: 21300,
      tags: ["race"],
      why: "Полумарафон из протокола",
    });
    assert(!act.isError, JSON.stringify(act.data));
    const activityId = act.data.activity.id;

    const race = await h.call("upsert_event", {
      fields: {
        name: "Новосибирский полумарафон",
        sport: "run",
        status: "done",
        datePrecision: "day",
        dateFrom: "2026-09-14",
        dateTo: "2026-09-14",
        distanceM: 21097,
        result: { timeSec: 6085, place: "112/900", notes: "Ровно до 15 км, потом подсел" },
        activityId,
      },
      why: "Прошлый старт",
    });
    assert(!race.isError, JSON.stringify(race.data));
    assertEquals(race.data.event.activityId, activityId);

    const past = (await h.call("list_events", { includePast: true, status: ["done"] })).data;
    assertEquals(past.events.map((e: { activityId: string }) => e.activityId), [activityId]);
    assertEquals(past.events[0].result.timeSec, 6085);
    assertEquals((await h.call("list_events")).data.events, []);

    // A missing activity is refused, not silently dropped.
    const bad = await h.call("upsert_event", {
      id: race.data.event.id,
      fields: { activityId: crypto.randomUUID() },
    });
    assert(bad.isError);
    assertEquals(bad.data.error, "not_found");

    // null unlinks; other fields stay.
    const unlinked = await h.call("upsert_event", {
      id: race.data.event.id,
      fields: { activityId: null },
    });
    assert(!unlinked.isError, JSON.stringify(unlinked.data));
    assertEquals(unlinked.data.event.activityId, undefined);
    assertEquals(unlinked.data.event.result.place, "112/900");

    // Isolation: another athlete cannot link our activity to their event.
    const other = crypto.randomUUID();
    const token = randomToken("z2a");
    await h.db.sql`insert into zone2.users (id, display_name) values (${other}, 'B')`;
    await h.db
      .sql`insert into zone2.oauth_tokens (token_hash, kind, client_id, user_id, scopes, resource, family_id, expires_at)
      values (${await sha256(token)}, 'access', 'test-client', ${other}, ${[
      "mcp",
    ]}, ${`${BASE}/mcp`}, ${crypto.randomUUID()}, now() + interval '3650 days')`;
    const res = await h.app.request("/mcp", {
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
        params: {
          name: "upsert_event",
          arguments: {
            fields: {
              name: "Чужой",
              sport: "run",
              status: "done",
              datePrecision: "day",
              dateFrom: "2026-09-14",
              dateTo: "2026-09-14",
              activityId,
            },
          },
        },
      }),
    });
    const out = (await res.json()).result;
    assert(out.isError);
    assertEquals(JSON.parse(out.content[0].text).error, "not_found");
  } finally {
    await h.drop();
  }
});
