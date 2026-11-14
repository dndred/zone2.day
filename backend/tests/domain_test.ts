import { assert, assertEquals } from "@std/assert";
import { Event, PlannedWorkout, Profile, Week } from "../src/domain/entities.ts";
import { estimate, hasPowerTargets, resolveTarget } from "../src/domain/plan.ts";
import { EnduranceStructure, StrengthStructure } from "../src/domain/structure.ts";
import { addDays, athleteNow, effectiveTimezone, mondayOf } from "../src/domain/time.ts";

const profile = Profile.parse({
  timezone: "Asia/Barnaul",
  travel: [{ from: "2027-05-28", to: "2027-06-04", timezone: "Europe/Moscow" }],
  run: { lthr: { low: 156, high: 162, basis: "8–10′ reps" }, thresholdPaceSecPerKm: 300 },
  bike: { ftp: 200 },
});

Deno.test("time: effective zone follows travel; athleteNow uses it", () => {
  assertEquals(effectiveTimezone(profile, "2027-05-27"), "Asia/Barnaul");
  assertEquals(effectiveTimezone(profile, "2027-06-01"), "Europe/Moscow");
  // 2027-06-01 20:00 UTC = 03:00 next day in Barnaul (+7), 23:00 in Moscow (+3)
  const now = athleteNow(profile, new Date("2027-06-01T20:00:00Z"));
  assertEquals(now.timezone, "Europe/Moscow");
  assertEquals(now.date, "2027-06-01");
  assertEquals(now.time, "23:00");
  assert(now.traveling);
  assertEquals(athleteNow(profile, new Date("2026-11-14T20:00:00Z")).date, "2026-11-15");
});

Deno.test("time: monday and day arithmetic", () => {
  assertEquals(mondayOf("2026-11-15"), "2026-11-09"); // Sunday → previous Monday
  assertEquals(mondayOf("2026-11-16"), "2026-11-16");
  assertEquals(addDays("2026-12-31", 1), "2027-01-01");
});

const hill = {
  steps: [
    {
      type: "step",
      id: "s1",
      kind: "warmup",
      duration: { type: "distance", m: 3500 },
      target: { metric: "hr", low: 125, high: 145 },
      secondary: [{ metric: "pace", low: 360, high: 380 }],
    },
    {
      type: "repeat",
      id: "r1",
      count: 6,
      steps: [
        {
          type: "step",
          id: "r1s1",
          kind: "work",
          duration: { type: "time", sec: 12 },
          target: { metric: "rpe", low: 9, high: 10 },
        },
        {
          type: "step",
          id: "r1s2",
          kind: "recovery",
          duration: { type: "time", sec: 105 },
          target: { metric: "hr", high: 140 },
        },
      ],
    },
    { type: "step", id: "s3", kind: "cooldown", duration: { type: "open" } },
  ],
};

Deno.test("structure: valid endurance workout with open step", () => {
  const s = EnduranceStructure.parse(hill);
  assertEquals(s.schema, 1);
});

Deno.test("structure: rejects duplicate ids and inverted ranges", () => {
  const dup = structuredClone(hill);
  dup.steps[2].id = "s1";
  assert(!EnduranceStructure.safeParse(dup).success);
  const bad = structuredClone(hill);
  (bad.steps[0] as { target: { low: number; high: number } }).target = {
    low: 150,
    high: 140,
  } as never;
  assert(!EnduranceStructure.safeParse(bad).success);
});

Deno.test("structure: strength needs sets or setList", () => {
  assert(
    StrengthStructure.safeParse({
      items: [{ type: "exercise", id: "e1", exercise: "RDL", sets: 2, reps: 8, weightKg: 55 }],
    }).success,
  );
  assert(
    !StrengthStructure.safeParse({
      items: [{ type: "exercise", id: "e1", exercise: "RDL", reps: 8 }],
    }).success,
  );
});

Deno.test("planned workout validates structure per sport", () => {
  const base = {
    id: crypto.randomUUID(),
    date: "2026-11-16",
    order: 0,
    sport: "run",
    title: "Hills",
    execution: "workoutkit",
  };
  assert(PlannedWorkout.safeParse({ ...base, structure: hill }).success);
  const r = PlannedWorkout.safeParse({
    ...base,
    sport: "strength",
    execution: "none",
    structure: hill,
  });
  assert(!r.success);
  assertEquals(r.error!.issues[0].path[0], "structure");
});

Deno.test("resolve: % of threshold → absolute; range threshold uses midpoint", () => {
  const hr = resolveTarget(
    { metric: "hr", low: 80, high: 90, unit: "pct_threshold" },
    "run",
    profile,
  );
  assertEquals([hr.low, hr.high], [127, 143]); // 159 × 0.8 / 0.9
  assert(hr.basis?.includes("156–162"));
  const pace = resolveTarget(
    { metric: "pace", low: 80, high: 90, unit: "pct_threshold" },
    "run",
    profile,
  );
  assertEquals([pace.low, pace.high], [333, 375]); // faster (lower) first
  const power = resolveTarget(
    { metric: "power", low: 55, high: 75, unit: "pct_threshold" },
    "bike",
    profile,
  );
  assertEquals([power.low, power.high], [110, 150]);
  const none = resolveTarget({ metric: "pace", low: 90, unit: "pct_threshold" }, "swim", profile);
  assert(none.unresolved);
});

Deno.test("estimate: time steps sum, distance via pace, open counted as unknown", () => {
  const e = estimate(hill, "run", profile);
  // warmup 3500 m at mid 370 s/km = 1295 s; repeats 6 × 117 s = 702 s; cooldown unknown
  assertEquals(e.durationSec, 1295 + 702);
  assertEquals(e.unknownSteps, 1);
  assertEquals(e.distanceM, null);
});

Deno.test("power targets detection (.zwo only when present)", () => {
  assert(!hasPowerTargets(hill));
  assert(hasPowerTargets({
    steps: [{
      type: "step",
      id: "a",
      kind: "work",
      duration: { type: "time", sec: 600 },
      target: { metric: "power", low: 180, high: 200 },
    }],
  }));
});

Deno.test("week must start on Monday; event date window rules", () => {
  assert(Week.safeParse({ weekStart: "2026-11-16" }).success);
  assert(!Week.safeParse({ weekStart: "2026-11-15" }).success);
  const ev = {
    id: crypto.randomUUID(),
    name: "Brevet 200",
    sport: "brevet",
    status: "idea",
    datePrecision: "month_part",
    dateFrom: "2027-06-01",
    dateTo: "2027-06-10",
    dateText: "начало июня 2027",
  };
  assert(Event.safeParse(ev).success);
  assert(!Event.safeParse({ ...ev, datePrecision: "day" }).success);
});
