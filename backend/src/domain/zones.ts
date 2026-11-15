// Zones applied at read time to the per-activity histograms (domain/analysis.ts), so changing a
// threshold needs no recompute. Source, in order: explicit zones in the profile → threshold model
// (LTHR: Friel; FTP: Coggan) → max HR (profile, else observed in the athlete's data, low confidence).
import type { Profile, Threshold } from "./entities.ts";
import type { Hist } from "./analysis.ts";

export type Family = "run" | "bike";
export type Confidence = "high" | "medium" | "low";

export interface ZoneSet {
  metric: "hr" | "power";
  /** Lower bounds of zones 2…n (zone 1 is everything below bounds[0]). */
  bounds: number[];
  basis: string;
  confidence: Confidence;
  /** Which zones count as low / moderate / high intensity (3-zone polarization, by index). */
  three: { low: number[]; mid: number[]; high: number[] };
}

const mid = (t: Threshold): number => (typeof t === "number" ? t : (t.low + t.high) / 2);
const showT = (t: Threshold): string =>
  typeof t === "number" ? String(t) : `${t.low}–${t.high} (mid ${mid(t)})`;

/** Sport → zone family: bike zones for bike, run zones (the athlete's main HR model) elsewhere. */
export function familyOf(sport: string): Family {
  return sport === "bike" ? "bike" : "run";
}

function threeOf(n: number): ZoneSet["three"] {
  const idx = Array.from({ length: n }, (_, i) => i);
  if (n <= 3) return { low: [0], mid: n > 1 ? [1] : [], high: n > 2 ? [2] : [] };
  return { low: [0, 1], mid: [2], high: idx.slice(3) };
}

const scaled = (base: number, pcts: number[]) => pcts.map((p) => Math.round(base * p));

/**
 * HR zones for a family. `observedMaxHr` is the fallback when the profile has neither zones,
 * LTHR nor max HR (computed from the athlete's activities by the caller).
 */
export function hrZones(p: Profile, family: Family, observedMaxHr?: number | null): ZoneSet | null {
  const own = family === "bike" ? p.bike : p.run;
  const other = family === "bike" ? p.run : null;
  const custom = own?.hrZones?.length ? own.hrZones : other?.hrZones?.length ? other.hrZones : null;
  if (custom) {
    const b = [...custom].sort((x, y) => x - y);
    return {
      metric: "hr",
      bounds: b,
      basis: `${family === "bike" && !own?.hrZones?.length ? "run" : family}.hrZones (custom)`,
      confidence: "high",
      three: threeOf(b.length + 1),
    };
  }
  const lthr = own?.lthr ?? (other?.lthr ?? null);
  if (lthr) {
    const fromRun = family === "bike" && !own?.lthr;
    // Friel: run Z1 <85 %, Z2 85–89, Z3 90–94, Z4 95–99, Z5 ≥100 % LTHR; bike 81/90/94/100.
    const pcts = family === "bike" && !fromRun ? [0.81, 0.9, 0.94, 1] : [0.85, 0.9, 0.95, 1];
    return {
      metric: "hr",
      bounds: scaled(mid(lthr), pcts),
      basis: `Friel 5 zones from ${fromRun ? "run" : family}.lthr ${showT(lthr)}`,
      confidence: typeof lthr === "number" ? "high" : "medium",
      three: threeOf(5),
    };
  }
  const max = own?.maxHr ?? other?.maxHr;
  if (max) {
    return {
      metric: "hr",
      bounds: scaled(max, [0.6, 0.7, 0.8, 0.9]),
      basis: `5 zones at 60/70/80/90 % of max HR ${max} (profile)`,
      confidence: "medium",
      three: threeOf(5),
    };
  }
  if (observedMaxHr) {
    return {
      metric: "hr",
      bounds: scaled(observedMaxHr, [0.6, 0.7, 0.8, 0.9]),
      basis:
        `5 zones at 60/70/80/90 % of max HR ${observedMaxHr} observed in the last year (no zones, LTHR or max HR in the profile)`,
      confidence: "low",
      three: threeOf(5),
    };
  }
  return null;
}

/** Bike power zones: custom, else Coggan 7 zones from FTP. Run power has no threshold yet. */
export function powerZones(p: Profile, family: Family): ZoneSet | null {
  if (family !== "bike") return null;
  if (p.bike?.powerZones?.length) {
    const b = [...p.bike.powerZones].sort((x, y) => x - y);
    return {
      metric: "power",
      bounds: b,
      basis: "bike.powerZones (custom)",
      confidence: "high",
      three: threeOf(b.length + 1),
    };
  }
  const ftp = p.bike?.ftp;
  if (!ftp) return null;
  return {
    metric: "power",
    // Coggan: Z1 <56 %, Z2 56–75, Z3 76–90, Z4 91–105, Z5 106–120, Z6 121–150, Z7 >150 % FTP.
    bounds: scaled(mid(ftp), [0.56, 0.76, 0.91, 1.06, 1.21, 1.51]),
    basis: `Coggan 7 zones from bike.ftp ${showT(ftp)}`,
    confidence: typeof ftp === "number" ? "high" : "medium",
    three: { low: [0, 1], mid: [2], high: [3, 4, 5, 6] },
  };
}

/** Seconds per zone (length = bounds.length + 1). A bin goes to the zone of its lower edge. */
export function distribute(h: Hist, z: ZoneSet): number[] {
  const out = new Array(z.bounds.length + 1).fill(0);
  h.sec.forEach((sec, i) => {
    if (!sec) return;
    const v = h.lo + i * h.step;
    let k = 0;
    while (k < z.bounds.length && v >= z.bounds[k]) k++;
    out[k] += sec;
  });
  return out;
}

/** Human-readable range of each zone: "<130", "130–144", "≥172". */
export function zoneRanges(z: ZoneSet): string[] {
  const b = z.bounds;
  return Array.from(
    { length: b.length + 1 },
    (_, k) => k === 0 ? `<${b[0]}` : k === b.length ? `≥${b[k - 1]}` : `${b[k - 1]}–${b[k] - 1}`,
  );
}

export function threeSplit(seconds: number[], z: ZoneSet) {
  const sum = (ix: number[]) => ix.reduce((a, i) => a + (seconds[i] ?? 0), 0);
  return { lowSec: sum(z.three.low), midSec: sum(z.three.mid), highSec: sum(z.three.high) };
}

/** Max HR from per-activity maxima: 3rd highest of the last year (single spikes are artefacts). */
export function observedMaxHr(maxima: number[]): number | null {
  const xs = maxima.filter((x) => x > 100 && x < 230).sort((a, b) => b - a);
  return xs.length >= 5 ? Math.round(xs[2]) : null;
}

/** Edwards TRIMP: minutes in HR zone k × k (5-zone models only; other zone counts → null). */
export function edwardsTrimp(seconds: number[]): number | null {
  if (seconds.length !== 5) return null;
  return Math.round(seconds.reduce((a, s, k) => a + (s / 60) * (k + 1), 0));
}
