// Raw HealthKit dump of an activity → resampled curves (shared by MCP and the Sync API).
import type { ActivityStore } from "../db/activities.ts";
import { HealthKitDump, streams } from "../domain/healthkit.ts";
import { fitToDump } from "../domain/fit.ts";
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
  const files = await activities.files(a.id);
  const file = files.find((f) => f.kind === "healthkit_dump") ??
    files.find((f) => f.kind === "fit_original");
  if (!file) throw new NoStreamsError("this activity has no raw data (entered manually?)");
  const raw = await blobs.get(file.key);
  if (!raw) throw new NoStreamsError("raw file is missing in storage");
  if (file.kind === "fit_original") return fitToDump(raw, a.sourceId, a.startAt);
  return HealthKitDump.parse(JSON.parse(new TextDecoder().decode(await gunzip(raw))));
}

/**
 * Channels the app charts: heart rate, speed (m/s), power, cadence, altitude; lat/lon for the
 * route map (always present as columns, all null without a route — the app tells an old cache by
 * their absence).
 */
export const APP_CHANNELS = [
  "heartRate",
  "speed",
  "runningPower",
  "cyclingPower",
  "cadence",
  "altitude",
  "lat",
  "lon",
];

export function appStreams(dump: HealthKitDump, maxPoints: number) {
  const to = dump.workout.durationSec;
  const buckets = Math.max(1, Math.min(maxPoints, Math.ceil(to)));
  const columns = streams(dump, APP_CHANNELS, 0, to, buckets);
  return { bucketSec: Math.round((to / buckets) * 10) / 10, columns };
}
