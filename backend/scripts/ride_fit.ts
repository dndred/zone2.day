// zone2 Ride (Mac) record → FIT file next to it (docs/11-trainer.md). The record is a HealthKit
// dump, so the same encoder as for Health workouts applies.
// Usage: deno run -A backend/scripts/ride_fit.ts <ride.json>...
import { dumpToFit } from "../src/domain/fit_encode.ts";
import { HealthKitDump, summarize } from "../src/domain/healthkit.ts";

for (const path of Deno.args) {
  const dump = HealthKitDump.parse(JSON.parse(await Deno.readTextFile(path)));
  const out = path.replace(/\.json$/, "") + ".fit";
  await Deno.writeFile(out, dumpToFit(dump));
  console.log(out, JSON.stringify(summarize(dump)));
}
