// update_activity: coach/athlete notes, append, clear, revert, isolation; profile has no free text.
import { assert, assertEquals, assertStringIncludes } from "@std/assert";
import { randomToken, sha256 } from "../src/auth/crypto.ts";
import { mcpHarness } from "./helpers/mcp.ts";

Deno.test("update_activity: notes, append, clear, revert, isolation", async () => {
  const h = await mcpHarness({ now: "2026-11-17T10:00:00Z" });
  try {
    await h.call("update_profile", { patch: { timezone: "Asia/Barnaul" }, why: "пояс" });
    const created = await h.call("create_activity", {
      sport: "run",
      start: "2026-11-16T08:00",
      durationSec: 3600,
      distanceM: 10000,
      athleteNotes: "Ноги тяжёлые",
      why: "со слов атлета",
    });
    assert(!created.isError, JSON.stringify(created.data));
    const id = created.data.activity.id;

    const first = await h.call("update_activity", {
      id,
      coachNotes: "Ровно, HR в коридоре.",
      rpe: 4,
      why: "разбор",
    });
    assert(!first.isError, JSON.stringify(first.data));
    assertEquals(first.data.activity.coachNotes, "Ровно, HR в коридоре.");
    assertEquals(first.data.activity.rpe, 4);
    assertEquals(first.data.activity.athleteNotes, "Ноги тяжёлые");

    const appended = await h.call("update_activity", {
      id,
      coachNotes: "Вывод: объём держит.",
      athleteNotes: "К концу полегчало",
      append: true,
    });
    assert(!appended.isError, JSON.stringify(appended.data));
    assertEquals(
      appended.data.activity.coachNotes,
      "Ровно, HR в коридоре.\n\nВывод: объём держит.",
    );
    assertEquals(appended.data.activity.athleteNotes, "Ноги тяжёлые\n\nК концу полегчало");

    // Append past the limit fails and writes nothing.
    const long = await h.call("update_activity", {
      id,
      coachNotes: "x".repeat(12_000),
      append: true,
    });
    assert(long.isError);
    assertStringIncludes(JSON.stringify(long.data), "too_long");

    // Nothing to change.
    assert((await h.call("update_activity", { id })).isError);

    // null clears.
    const cleared = await h.call("update_activity", { id, rpe: null });
    assertEquals(cleared.data.activity.rpe, undefined);

    // get_activity shows the notes.
    const got = (await h.call("get_activity", { id })).data.activity;
    assertEquals(got.coachNotes, "Ровно, HR в коридоре.\n\nВывод: объём держит.");

    // Revert the append: both notes come back as they were.
    const rev = await h.call("revert_change", { changeId: appended.data.changeId, why: "откат" });
    assert(!rev.isError, JSON.stringify(rev.data));
    const back = (await h.call("get_activity", { id })).data.activity;
    assertEquals(back.coachNotes, "Ровно, HR в коридоре.");
    assertEquals(back.athleteNotes, "Ноги тяжёлые");
    assertEquals(back.rpe, undefined);

    // Revert the first write: coachNotes cleared, rpe back to unset.
    await h.call("revert_change", { changeId: first.data.changeId, why: "откат" });
    const orig = (await h.call("get_activity", { id })).data.activity;
    assertEquals(orig.coachNotes, undefined);

    // Isolation: another athlete cannot write on it.
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
        params: { name: "update_activity", arguments: { id, coachNotes: "чужое" } },
      }),
    });
    const theirs = (await res.json()).result;
    assert(theirs.isError);
    assertStringIncludes(theirs.content[0].text, "not_found");
    assertEquals((await h.call("get_activity", { id })).data.activity.coachNotes, undefined);
  } finally {
    await h.drop();
  }
});

Deno.test("update_profile: free-form notes are not a profile field", async () => {
  const h = await mcpHarness();
  try {
    const r = await h.call("update_profile", { patch: { notes: "любит зиму" }, why: "факт" });
    assert(r.isError);
    assertStringIncludes(JSON.stringify(r.data), "write_notebook");
  } finally {
    await h.drop();
  }
});
