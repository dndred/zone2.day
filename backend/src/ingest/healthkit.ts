// HealthKit dump → activity (docs/05-sync.md §6): store the original, summarize, dedupe, match plan.
import type { ActivityStore } from "../db/activities.ts";
import type { DocumentStore } from "../db/documents.ts";
import { sha256Bytes } from "../auth/crypto.ts";
import { DEFAULT_PROFILE, type PlannedWorkout, Profile } from "../domain/entities.ts";
import { HealthKitDump, lapsOf, sourcePriority, summarize } from "../domain/healthkit.ts";
import { effectiveTimezone, isValidTimeZone, localParts } from "../domain/time.ts";
import type { BlobStore } from "../ports/blob.ts";

export interface IngestDeps {
  activities: ActivityStore;
  docs: DocumentStore;
  blobs: BlobStore;
}

export interface IngestResult {
  activityId: string;
  created: boolean;
  sport: string;
  localDate: string;
  plannedWorkoutId: string | null;
  duplicateOf: string | null;
}

const isGzip = (b: Uint8Array) => b.length > 2 && b[0] === 0x1f && b[1] === 0x8b;

async function pipe(bytes: Uint8Array, stream: CompressionStream | DecompressionStream) {
  const out = new Blob([bytes as BlobPart]).stream().pipeThrough(stream);
  return new Uint8Array(await new Response(out).arrayBuffer());
}
export const gunzip = (b: Uint8Array) => pipe(b, new DecompressionStream("gzip"));
export const gzip = (b: Uint8Array) => pipe(b, new CompressionStream("gzip"));

export async function ingestHealthKit(
  deps: IngestDeps,
  userId: string,
  raw: Uint8Array,
): Promise<IngestResult> {
  const json = isGzip(raw) ? await gunzip(raw) : raw;
  const gz = isGzip(raw) ? raw : await gzip(raw);
  const dump = HealthKitDump.parse(JSON.parse(new TextDecoder().decode(json)));
  const summary = summarize(dump);
  const laps = lapsOf(dump);

  const profileDoc = await deps.docs.get<Profile>(userId, "profile", "profile");
  const profile = profileDoc ? Profile.parse(profileDoc.data) : DEFAULT_PROFILE;
  const start = new Date(dump.workout.start);
  const homeDate = localParts(start, profile.timezone).date;
  const tz = summary.timezone && isValidTimeZone(summary.timezone)
    ? summary.timezone
    : effectiveTimezone(profile, homeDate);
  const localDate = localParts(start, tz).date;

  // Original first (idempotent key by HealthKit uuid), then the row.
  const key = `${userId}/healthkit/${dump.workout.uuid}.json.gz`;
  await deps.blobs.put(key, gz, "application/gzip");

  const { row, created } = await deps.activities.upsert(userId, {
    source: "healthkit",
    sourceId: dump.workout.uuid,
    sourceApp: dump.workout.source.name,
    sport: summary.sport,
    subSport: summary.subSport,
    activityType: dump.workout.activityType,
    startAt: start,
    endAt: new Date(dump.workout.end),
    timezone: tz,
    localDate,
    durationSec: summary.durationSec,
    distanceM: summary.distanceM,
    summary,
    laps,
  });
  await deps.activities.addFile(row.id, {
    kind: "healthkit_dump",
    key,
    bytes: gz.length,
    sha256: await sha256Bytes(gz),
  });

  // Same session from two sources (e.g. Strava's copy of a ride): keep the better source.
  let duplicateOf: string | null = null;
  const mine = sourcePriority(summary.sourceBundle);
  for (
    const other of await deps.activities.overlapping(
      userId,
      row.sport,
      row.startAt,
      row.endAt,
      row.id,
    )
  ) {
    if (other.duplicateOf) continue;
    const theirs = sourcePriority(String(other.summary.sourceBundle ?? ""));
    if (mine > theirs) {
      duplicateOf = other.id;
      await deps.activities.setDuplicate(userId, row.id, other.id);
    } else if (mine < theirs) {
      await deps.activities.setDuplicate(userId, other.id, row.id);
      if (other.plannedWorkoutId && !row.plannedWorkoutId) {
        await deps.activities.setPlanned(userId, row.id, other.plannedWorkoutId);
        row.plannedWorkoutId = other.plannedWorkoutId;
      }
    }
  }

  // Match to the plan: same local date and sport, not skipped, not taken; lowest order first.
  let plannedWorkoutId = row.plannedWorkoutId;
  if (!duplicateOf && !plannedWorkoutId && row.sport !== "other") {
    const day = await deps.docs.listByDate<PlannedWorkout>(
      userId,
      "planned_workout",
      localDate,
      localDate,
    );
    const candidates = day.map((d) => d.data).filter((w) => w.sport === row.sport && !w.skipped);
    const taken = await deps.activities.byPlanned(userId, candidates.map((w) => w.id));
    const pick = candidates.sort((a, b) => a.order - b.order).find((w) => !taken.has(w.id));
    if (pick) {
      await deps.activities.setPlanned(userId, row.id, pick.id);
      plannedWorkoutId = pick.id;
    }
  }

  return {
    activityId: row.id,
    created,
    sport: row.sport,
    localDate,
    plannedWorkoutId: duplicateOf ? null : plannedWorkoutId,
    duplicateOf,
  };
}
