// Synthetic HealthKit dumps shaped like real Apple Watch exports (spike S1).
import type { HealthKitDump } from "../../src/domain/healthkit.ts";

export interface DumpOpts {
  uuid?: string;
  start?: string; // ISO UTC
  minutes?: number;
  activityType?: number; // 37 run, 13 bike, 46 swim, 20 strength
  distanceM?: number | null;
  hr?: number; // base HR
  sourceName?: string;
  bundleId?: string;
  indoor?: boolean;
  timezone?: string;
  segments?: number; // equal segments as workout events
  pauseSec?: number; // one pause in the middle
  standStartSec?: number; // standing still at the start (e.g. waiting for a parkrun start)
}

export function makeDump(o: DumpOpts = {}): HealthKitDump {
  const minutes = o.minutes ?? 40;
  const duration = minutes * 60;
  const start = new Date(o.start ?? "2026-11-16T01:00:00Z");
  const end = new Date(start.getTime() + duration * 1000);
  const iso = (sec: number) => new Date(start.getTime() + sec * 1000).toISOString();
  const type = o.activityType ?? 37;
  const distance = o.distanceM === undefined
    ? (type === 37 ? 8000 : type === 13 ? 20000 : null)
    : o.distanceM;
  const hrBase = o.hr ?? 140;
  const hr: [number, number, number][] = [];
  for (let t = 0; t < duration; t += 5) {
    hr.push([t, t, hrBase + Math.round(10 * Math.sin(t / 300))]);
  }
  const samples: HealthKitDump["samples"] = { heartRate: { unit: "count/min", values: hr } };
  if (distance) {
    const key = type === 13
      ? "distanceCycling"
      : type === 46
      ? "distanceSwimming"
      : "distanceWalkingRunning";
    const stand = o.standStartSec ?? 0;
    const per = distance / ((duration - stand) / 10);
    samples[key] = {
      unit: "m",
      values: Array.from(
        { length: duration / 10 },
        (_, i) => [i * 10, i * 10 + 10, i * 10 < stand ? 0 : per] as [number, number, number],
      ),
    };
  }
  if (type === 37) {
    samples.runningPower = {
      unit: "W",
      values: hr.map(([t]) => [t, t, 250] as [number, number, number]),
    };
  }
  const events: HealthKitDump["workout"]["events"] = [];
  const segs = o.segments ?? 0;
  for (let i = 0; i < segs; i++) {
    events.push({
      type: "segment",
      start: iso((i * duration) / segs),
      end: iso(((i + 1) * duration) / segs),
      metadata: {},
    });
  }
  if (o.pauseSec) {
    events.push({ type: "pause", start: iso(duration / 2), end: iso(duration / 2), metadata: {} });
    events.push({
      type: "resume",
      start: iso(duration / 2 + o.pauseSec),
      end: iso(duration / 2 + o.pauseSec),
      metadata: {},
    });
  }
  return {
    schema: 1,
    exportedAt: end.toISOString(),
    workout: {
      uuid: o.uuid ?? crypto.randomUUID().toUpperCase(),
      activityType: type,
      start: start.toISOString(),
      end: end.toISOString(),
      durationSec: duration,
      totalDistanceM: distance,
      totalEnergyKcal: 500,
      source: {
        name: o.sourceName ?? "Andrei’s Apple Watch",
        bundleId: o.bundleId ?? "com.apple.health.ABC",
      },
      device: { name: "Apple Watch", model: "Watch" },
      metadata: {
        HKIndoorWorkout: o.indoor ?? false,
        HKTimeZone: o.timezone ?? "Asia/Barnaul",
        HKWeatherTemperature: { value: 25.9, unit: "degF" },
        HKWeatherHumidity: { value: 0.88, unit: "%" },
        HKElevationAscended: { value: 4200, unit: "cm" },
      },
      activities: [],
      events,
    },
    samples,
    route: type === 37
      ? Array.from(
        { length: duration / 2 },
        (_, i) => [i * 2, 53.35 + i * 1e-5, 83.76, 150, 5, 3, 3.3, 90],
      )
      : [],
  };
}
