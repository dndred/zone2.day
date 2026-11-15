// Raw HealthKit dump of an activity → resampled curves (shared by MCP and the Sync API).
import type { ActivityStore } from "../db/activities.ts";
import { HealthKitDump, streams } from "../domain/healthkit.ts";
import { gunzip } from "../ingest/healthkit.ts";
import type { BlobStore } from "../ports/blob.ts";

export class NoStreamsError extends Error {}

export async function loadDump(
  activities: ActivityStore,
  blobs: BlobStore,
  userId: string,
  id: string,
): Promise<HealthKitDump | null> {
  const a = await activities.get(userId, id);
  if (!a) return null;
  const file = (await activities.files(a.id)).find((f) => f.kind === "healthkit_dump");
  if (!file) throw new NoStreamsError("this activity has no raw data");
  const raw = await blobs.get(file.key);
  if (!raw) throw new NoStreamsError("raw file is missing in storage");
  return HealthKitDump.parse(JSON.parse(new TextDecoder().decode(await gunzip(raw))));
}

/** Channels the app charts: heart rate, speed (m/s), power, cadence, altitude. */
export const APP_CHANNELS = [
  "heartRate",
  "speed",
  "runningPower",
  "cyclingPower",
  "cadence",
  "altitude",
];

export function appStreams(dump: HealthKitDump, maxPoints: number) {
  const to = dump.workout.durationSec;
  const buckets = Math.max(1, Math.min(maxPoints, Math.ceil(to)));
  const columns = streams(dump, APP_CHANNELS, 0, to, buckets);
  return { bucketSec: Math.round((to / buckets) * 10) / 10, columns };
}
