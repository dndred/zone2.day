// Spike S3: HealthKit dump → FIT → decode → compare (docs/spikes/S3-dump-to-fit.md).
// Usage: deno run -A backend/scripts/s3_fit_roundtrip.ts <dump.json[.gz]>... [--out dir]
import { Decoder, Stream } from "@garmin/fitsdk";
import { fitToDump } from "../src/domain/fit.ts";
import { dumpToFit } from "../src/domain/fit_encode.ts";
import { HealthKitDump, lapsOf, summarize } from "../src/domain/healthkit.ts";

const args = [...Deno.args];
const oi = args.indexOf("--out");
const outDir = oi >= 0 ? args.splice(oi, 2)[1] : null;

async function load(path: string): Promise<HealthKitDump> {
  let bytes = await Deno.readFile(path);
  if (path.endsWith(".gz")) {
    bytes = new Uint8Array(
      await new Response(new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip")))
        .arrayBuffer(),
    );
  }
  return HealthKitDump.parse(JSON.parse(new TextDecoder().decode(bytes)));
}

const pct = (a: number | null | undefined, b: number | null | undefined) =>
  a == null || b == null
    ? (a == b ? "=" : `${a}→${b}`)
    : a === 0
    ? `${b}`
    : `${(((b - a) / a) * 100).toFixed(2)}%`;

for (const path of args) {
  const name = path.split("/").pop()!.replace(/\.json(\.gz)?$/, "");
  const dump = await load(path);
  const t0 = performance.now();
  const fit = dumpToFit(dump);
  const encMs = performance.now() - t0;
  const dec = new Decoder(Stream.fromByteArray(Array.from(fit)));
  const integrity = dec.checkIntegrity();
  const { messages, errors } = new Decoder(Stream.fromByteArray(Array.from(fit))).read();
  const back = fitToDump(fit, "rt", new Date());
  const a = summarize(dump);
  const b = summarize(back);
  const la = lapsOf(dump).filter((l) =>
    l.kind === "manual" || l.kind === "segment" || l.kind === "split_km"
  );
  const lb = lapsOf(back);
  const firstKind = la.find((l) => l.kind === "manual") ? "manual" : la[0]?.kind;
  const laA = la.filter((l) => l.kind === firstKind);
  const lapDistDiff = laA.length === lb.length
    ? Math.max(0, ...laA.map((l, i) => Math.abs((l.distanceM ?? 0) - (lb[i].distanceM ?? 0))))
    : null;
  const lapHrDiff = laA.length === lb.length
    ? Math.max(0, ...laA.map((l, i) => Math.abs((l.avgHr ?? 0) - (lb[i].avgHr ?? 0))))
    : null;
  console.log(JSON.stringify({
    name,
    sport: `${a.sport}/${a.subSport ?? ""}`,
    durMin: Math.round(dump.workout.durationSec / 60),
    fitKB: Math.round(fit.length / 1024),
    encodeMs: Math.round(encMs),
    integrity,
    decodeErrors: errors.length,
    records: messages.recordMesgs?.length ?? 0,
    lengths: messages.lengthMesgs?.length ?? 0,
    laps: `${laA.length}(${firstKind ?? "-"})→${lb.length}`,
    lapMaxDistDiffM: lapDistDiff === null ? null : Math.round(lapDistDiff * 10) / 10,
    lapMaxHrDiff: lapHrDiff,
    distance: pct(a.distanceM, b.distanceM),
    elapsed: `${a.elapsedSec}→${b.elapsedSec}`,
    moving: `${a.movingSec}→${b.movingSec}`,
    hrAvg: `${a.hr?.avg}→${b.hr?.avg}`,
    hrMax: `${a.hr?.max}→${b.hr?.max}`,
    power: `${a.running?.powerAvg ?? a.cycling?.powerAvg ?? "-"}→${
      b.running?.powerAvg ?? b.cycling?.powerAvg ?? "-"
    }`,
    cadence: `${a.running?.cadenceSpm ?? a.cycling?.cadenceAvg ?? "-"}→${
      b.running?.cadenceSpm ?? b.cycling?.cadenceAvg ?? "-"
    }`,
    pace: `${a.paceSecPerKm ?? a.paceSecPer100m ?? "-"}→${
      b.paceSecPerKm ?? b.paceSecPer100m ?? "-"
    }`,
    route: `${a.routePoints}→${b.routePoints}`,
    ascent: `${a.elevationGainM}→${b.elevationGainM}`,
    kcal: `${a.energyKcal}→${b.energyKcal}`,
  }));
  if (outDir) await Deno.writeFile(`${outDir}/${name}.fit`, fit);
}
