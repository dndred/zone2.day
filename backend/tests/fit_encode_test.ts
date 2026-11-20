// Dump → FIT (spike S3): the file is valid for the Garmin SDK and decodes back to the same summary.
import { assert, assertAlmostEquals, assertEquals } from "@std/assert";
import { Decoder, Stream } from "@garmin/fitsdk";
import { fitToDump } from "../src/domain/fit.ts";
import { dumpToFit } from "../src/domain/fit_encode.ts";
import { lapsOf, summarize } from "../src/domain/healthkit.ts";
import { makeDump } from "./helpers/dump.ts";

function roundTrip(dump: ReturnType<typeof makeDump>) {
  const fit = dumpToFit(dump);
  assert(new Decoder(Stream.fromByteArray(Array.from(fit))).checkIntegrity());
  const { errors } = new Decoder(Stream.fromByteArray(Array.from(fit))).read();
  assertEquals(errors, []);
  return { fit, back: fitToDump(fit, "rt", new Date()) };
}

Deno.test("dump → FIT → dump: run with manual intervals keeps totals and laps", () => {
  const dump = makeDump({ minutes: 40, markers: [600, 1800] });
  const { back } = roundTrip(dump);
  const a = summarize(dump);
  const b = summarize(back);
  assertEquals(b.sport, "run");
  assertEquals(b.elapsedSec, a.elapsedSec);
  assertAlmostEquals(b.distanceM!, a.distanceM!, a.distanceM! * 0.001);
  assertEquals(b.hr?.max, a.hr?.max);
  assertAlmostEquals(b.hr!.avg!, a.hr!.avg!, 1);
  const la = lapsOf(dump).filter((l) => l.kind === "manual");
  const lb = lapsOf(back);
  assertEquals(lb.length, la.length);
  la.forEach((l, i) => {
    assertAlmostEquals(lb[i].startSec, l.startSec, 1);
    assertAlmostEquals(lb[i].distanceM!, l.distanceM!, 5);
  });
});

Deno.test("dump → FIT → dump: a pause keeps timer time apart from wall clock", () => {
  const dump = makeDump({ minutes: 30, pauseSec: 300 });
  const { back } = roundTrip(dump);
  assertEquals(Math.round(back.workout.durationSec), Math.round(dump.workout.durationSec));
  assertEquals(back.workout.end.slice(0, 19), dump.workout.end.slice(0, 19));
  assertEquals(back.workout.events.filter((e) => e.type === "pause").length, 1);
});

Deno.test("dump → FIT: bike and strength encode without errors", () => {
  for (const activityType of [13, 20]) {
    const { back } = roundTrip(makeDump({ activityType, minutes: 20 }));
    assertEquals(back.workout.activityType, activityType);
  }
});
