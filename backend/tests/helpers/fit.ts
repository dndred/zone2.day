// Synthetic FIT activity files (shaped like a MyWhoosh export: indoor ride, 1 Hz records with
// HR, power, cadence, speed and distance, one lap per workout step).
import { Encoder, Profile } from "@garmin/fitsdk";

export interface FitOpts {
  start?: string; // ISO UTC
  minutes?: number;
  laps?: number;
  sport?: string;
  subSport?: string;
  power?: number;
  hr?: number;
  speedMps?: number;
  manufacturer?: string;
}

export function makeFit(o: FitOpts = {}): Uint8Array {
  const start = new Date(o.start ?? "2026-11-16T12:00:00Z");
  const sec = (o.minutes ?? 60) * 60;
  const laps = o.laps ?? 3;
  const speed = o.speedMps ?? 9;
  const at = (s: number) => new Date(start.getTime() + s * 1000);
  const enc = new Encoder();
  enc.onMesg(Profile.MesgNum.FILE_ID, {
    type: "activity",
    manufacturer: o.manufacturer ?? "development",
    product: 1,
    productName: "MyWhoosh",
    timeCreated: start,
    serialNumber: 1234,
  });
  enc.onMesg(Profile.MesgNum.EVENT, { timestamp: start, event: "timer", eventType: "start" });
  for (let s = 0; s <= sec; s++) {
    enc.onMesg(Profile.MesgNum.RECORD, {
      timestamp: at(s),
      heartRate: (o.hr ?? 140) + Math.round(5 * Math.sin(s / 120)),
      power: (o.power ?? 200) + (s % 2 ? 10 : -10),
      cadence: 90,
      speed,
      distance: s * speed,
    });
  }
  const lapLen = sec / laps;
  for (let i = 0; i < laps; i++) {
    enc.onMesg(Profile.MesgNum.LAP, {
      timestamp: at((i + 1) * lapLen),
      startTime: at(i * lapLen),
      totalElapsedTime: lapLen,
      totalTimerTime: lapLen,
      totalDistance: lapLen * speed,
    });
  }
  enc.onMesg(Profile.MesgNum.EVENT, { timestamp: at(sec), event: "timer", eventType: "stopAll" });
  enc.onMesg(Profile.MesgNum.SESSION, {
    timestamp: at(sec),
    startTime: start,
    sport: o.sport ?? "cycling",
    subSport: o.subSport ?? "virtualActivity",
    totalElapsedTime: sec,
    totalTimerTime: sec,
    totalDistance: sec * speed,
    totalCalories: 650,
  });
  enc.onMesg(Profile.MesgNum.ACTIVITY, {
    timestamp: at(sec),
    numSessions: 1,
    type: "manual",
    event: "activity",
    eventType: "stop",
  });
  return enc.close();
}
