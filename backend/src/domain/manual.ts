// Activity entered by hand (MCP create_activity): no samples, only what the athlete reported.
// Same summary shape as summarize() so lists, plan and the app treat it like any other activity.
import { SUMMARY_VERSION } from "./healthkit.ts";

export interface ManualInput {
  sport: "run" | "bike" | "swim" | "strength" | "other";
  subSport: string | null;
  startLocal: string; // HH:MM in the activity's zone
  timezone: string;
  elapsedSec: number;
  movingSec?: number;
  distanceM?: number;
  hrAvg?: number;
  hrMax?: number;
  powerAvg?: number;
  elevationGainM?: number;
  energyKcal?: number;
}

const NAMES: Record<string, string> = {
  run: "Run",
  bike: "Ride",
  swim: "Swim",
  strength: "Strength",
  other: "Workout",
};
const SUB_NAMES: Record<string, string> = {
  indoor_bike: "Indoor ride",
  treadmill: "Treadmill run",
  pool: "Pool swim",
  open_water: "Open water swim",
  walk: "Walk",
  hike: "Hike",
};
const INDOOR = new Set(["indoor_bike", "treadmill", "pool"]);

export function manualSummary(i: ManualInput) {
  const moving = i.movingSec ?? i.elapsedSec;
  const km = i.distanceM ? i.distanceM / 1000 : null;
  const foot = i.sport === "run" || i.subSport === "walk" || i.subSport === "hike";
  const virtual = i.subSport === "indoor_bike" || i.subSport === "treadmill";
  return {
    v: SUMMARY_VERSION,
    sport: i.sport,
    subSport: i.subSport,
    kind: "training" as const,
    name: (i.subSport && SUB_NAMES[i.subSport]) ?? NAMES[i.sport],
    startLocal: i.startLocal,
    elapsedSec: Math.round(i.elapsedSec),
    movingSec: Math.round(moving),
    movingBasis: i.movingSec !== undefined ? "entered by hand" : "= elapsed (not entered)",
    intervals: null,
    distanceM: i.distanceM ?? null,
    distanceKind: i.distanceM === undefined ? null : virtual ? "virtual" : "measured",
    paceSecPerKm: foot && km ? Math.round(moving / km) : null,
    paceElapsedSecPerKm: foot && km ? Math.round(i.elapsedSec / km) : null,
    paceSecPer100m: i.sport === "swim" && i.distanceM
      ? Math.round(moving / (i.distanceM / 100))
      : null,
    paceWithRestsSecPer100m: i.sport === "swim" && i.distanceM
      ? Math.round(i.elapsedSec / (i.distanceM / 100))
      : null,
    speedKmh: i.sport === "bike" && km ? Math.round(km / (moving / 3600) * 10) / 10 : null,
    hr: i.hrAvg !== undefined || i.hrMax !== undefined
      ? { avg: i.hrAvg ?? null, max: i.hrMax ?? null, samples: 0 }
      : null,
    elevationGainM: i.elevationGainM ?? null,
    energyKcal: i.energyKcal ?? null,
    weather: null,
    indoor: i.subSport ? INDOOR.has(i.subSport) : false,
    /** manual: entered by hand, no samples — no streams, laps or zones. */
    detail: "manual",
    running: i.sport === "run" ? { powerAvg: i.powerAvg ?? null } : undefined,
    cycling: i.sport === "bike" ? { powerAvg: i.powerAvg ?? null } : undefined,
    routePoints: 0,
    device: null,
    sourceApp: null,
    sourceBundle: "manual",
    timezone: i.timezone,
  };
}
