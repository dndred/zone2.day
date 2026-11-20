// Planned bike workout → .zwo (Zwift workout XML) for MyWhoosh. Pure function.
// Power in .zwo is a fraction of the FTP set in the trainer app, so absolute watts are divided by
// that FTP: the athlete rides exactly the planned watts only while MyWhoosh has the same FTP.
import type { Profile } from "./entities.ts";
import { type ResolvedTarget, resolveTarget } from "./plan.ts";
import { EnduranceStructure, type Step } from "./structure.ts";

export class ZwoError extends Error {
  constructor(message: string, readonly hint?: string) {
    super(message);
  }
}

export interface ZwoInput {
  title: string;
  goal?: string;
  notes?: string;
  structure?: unknown;
}

export interface ZwoResult {
  xml: string;
  durationSec: number;
  /** FTP the fractions are relative to (= FTP that must be set in MyWhoosh). */
  ftpW: number;
  warnings: string[];
}

const esc = (s: string) =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const frac = (w: number, ftp: number) => String(Math.round((w / ftp) * 1000) / 1000);

function stepSec(step: Step, warnings: string[]): number {
  const d = step.duration;
  if (d.type === "time") return d.sec;
  if (d.type === "open" && d.estimateSec) {
    warnings.push(`step '${step.id}' is open-ended; exported as ${d.estimateSec} s (estimateSec)`);
    return d.estimateSec;
  }
  throw new ZwoError(
    `step '${step.id}' has ${
      d.type === "open" ? "an open duration without estimateSec" : "a distance duration"
    }; .zwo supports only time`,
    "Give trainer steps a time duration (or estimateSec on open steps)",
  );
}

function power(step: Step, profile: Profile, warnings: string[]): ResolvedTarget | null {
  const t = [step.target, ...(step.secondary ?? [])].find((x) => x?.metric === "power");
  if (!t) return null;
  const r = resolveTarget(t, "bike", profile);
  if (r.unresolved) {
    throw new ZwoError(
      `step '${step.id}': ${r.unresolved}`,
      "Set bike.ftp (update_profile) or give power in watts",
    );
  }
  if (r.low === undefined && r.high === undefined) return null;
  if (r.low === undefined || r.high === undefined) {
    warnings.push(
      `step '${step.id}': one-sided power target exported as a fixed ${r.low ?? r.high} W`,
    );
  }
  return r;
}

function cadence(step: Step): number | undefined {
  const t = step.cadence ??
    [step.target, ...(step.secondary ?? [])].find((x) => x?.metric === "cadence");
  if (!t) return undefined;
  const lo = t.low ?? t.high;
  const hi = t.high ?? t.low;
  return lo === undefined || hi === undefined ? undefined : Math.round((lo + hi) / 2);
}

/**
 * Warmup/cooldown with a power range become ramps (warmup low→high, cooldown high→low; in .zwo
 * PowerLow is the start and PowerHigh the end for both). Other steps hold the middle of the range
 * (ERG). Steps without power are FreeRide. A 2-step time repeat with power on both → IntervalsT.
 */
export function buildZwo(w: ZwoInput, profile: Profile, ftpW: number): ZwoResult {
  const parsed = EnduranceStructure.safeParse(w.structure);
  if (!parsed.success) throw new ZwoError("workout has no endurance structure");
  const warnings: string[] = [];
  const lines: string[] = [];
  let total = 0;
  let anyPower = false;

  const element = (step: Step): string => {
    const sec = stepSec(step, warnings);
    total += sec;
    const p = power(step, profile, warnings);
    const cad = cadence(step);
    const cadAttr = cad ? ` Cadence="${cad}"` : "";
    if (!p) return `<FreeRide Duration="${sec}"${cadAttr}/>`;
    anyPower = true;
    const lo = p.low ?? p.high!;
    const hi = p.high ?? p.low!;
    if ((step.kind === "warmup" || step.kind === "cooldown") && lo !== hi) {
      const [start, end] = step.kind === "warmup" ? [lo, hi] : [hi, lo];
      const tag = step.kind === "warmup" ? "Warmup" : "Cooldown";
      return `<${tag} Duration="${sec}" PowerLow="${frac(start, ftpW)}" PowerHigh="${
        frac(end, ftpW)
      }"${cadAttr}/>`;
    }
    return `<SteadyState Duration="${sec}" Power="${frac((lo + hi) / 2, ftpW)}"${cadAttr}/>`;
  };

  for (const node of parsed.data.steps) {
    if (node.type === "step") {
      lines.push(element(node));
      continue;
    }
    const [on, off] = node.steps;
    const timed = node.steps.every((s) => s.duration.type === "time");
    const pOn = node.steps.length === 2 && timed ? power(on, profile, warnings) : null;
    const pOff = pOn ? power(off, profile, warnings) : null;
    if (pOn && pOff) {
      const mid = (r: ResolvedTarget) => ((r.low ?? r.high!) + (r.high ?? r.low!)) / 2;
      const onSec = stepSec(on, warnings);
      const offSec = stepSec(off, warnings);
      total += node.count * (onSec + offSec);
      anyPower = true;
      const cOn = cadence(on);
      const cOff = cadence(off);
      lines.push(
        `<IntervalsT Repeat="${node.count}" OnDuration="${onSec}" OffDuration="${offSec}" OnPower="${
          frac(mid(pOn), ftpW)
        }" OffPower="${frac(mid(pOff), ftpW)}"${cOn ? ` Cadence="${cOn}"` : ""}${
          cOff ? ` CadenceResting="${cOff}"` : ""
        }/>`,
      );
    } else {
      for (let i = 0; i < node.count; i++) for (const s of node.steps) lines.push(element(s));
    }
  }
  if (!anyPower) {
    throw new ZwoError(
      "workout has no power targets; .zwo (ERG) only makes sense with power",
      "Add power targets (W or % FTP) to the trainer steps",
    );
  }

  const description = [w.goal, w.notes].filter(Boolean).join("\n\n");
  const xml = [
    "<workout_file>",
    "  <author>zone2.day</author>",
    `  <name>${esc(w.title)}</name>`,
    `  <description>${esc(description)}</description>`,
    "  <sportType>bike</sportType>",
    "  <tags/>",
    "  <workout>",
    ...lines.map((l) => `    ${l}`),
    "  </workout>",
    "</workout_file>",
    "",
  ].join("\n");
  return { xml, durationSec: total, ftpW, warnings };
}
