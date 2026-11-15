// HealthKit dump → activity (docs/05-sync.md §6): store the original, summarize, dedupe, match plan.
// FIT files go through the same saveDump after conversion (ingest/fit.ts).
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
  opts: { storeOriginal?: boolean } = {},
): Promise<IngestResult> {
  const json = isGzip(raw) ? await gunzip(raw) : raw;
  const gz = isGzip(raw) ? raw : await gzip(raw);
  const dump = HealthKitDump.parse(JSON.parse(new TextDecoder().decode(json)));
  return await saveDump(deps, userId, dump, {
    source: "healthkit",
    sourceId: dump.workout.uuid,
    file: (opts.storeOriginal ?? true)
      ? {
        kind: "healthkit_dump",
        key: `${userId}/healthkit/${dump.workout.uuid}.json.gz`,
        body: gz,
        contentType: "application/gzip",
      }
      : undefined,
  });
}

export interface DumpSource {
  source: string;
  sourceId: string;
  /** Original to store (skipped when recomputing a summary from a stored original). */
  file?: { kind: string; key: string; body: Uint8Array; contentType: string };
  /** Link to this planned workout instead of matching automatically (validated by the caller). */
  plannedWorkoutId?: string;
}

/** Dump (from HealthKit or converted from FIT) → activity row: summary, laps, dedupe, plan. */
export async function saveDump(
  deps: IngestDeps,
  userId: string,
  dump: HealthKitDump,
  src: DumpSource,
): Promise<IngestResult> {
  const summary = summarize(dump);
  const laps = lapsOf(dump);

  const profileDoc = await deps.docs.get<Profile>(userId, "profile", "profile");
  const profile = profileDoc ? Profile.parse(profileDoc.data) : DEFAULT_PROFILE;
  const start = new Date(dump.workout.start);
  const homeDate = localParts(start, profile.timezone).date;
  const tz = summary.timezone && isValidTimeZone(summary.timezone)
    ? summary.timezone
    : effectiveTimezone(profile, homeDate);
  const local = localParts(start, tz);
  const localDate = local.date;
  // Sources without HKTimeZone (Strava copies, FIT files): start time in the athlete's zone that day.
  if (!summary.startLocal) summary.startLocal = local.time;

  // Original first (idempotent key), then the row.
  if (src.file) await deps.blobs.put(src.file.key, src.file.body, src.file.contentType);

  const { row, created } = await deps.activities.upsert(userId, {
    source: src.source,
    sourceId: src.sourceId,
    sourceApp: dump.workout.source.name,
    sport: summary.sport,
    subSport: summary.subSport,
    activityType: dump.workout.activityType,
    startAt: start,
    endAt: new Date(dump.workout.end),
    timezone: tz,
    localDate,
    durationSec: summary.elapsedSec,
    distanceM: summary.distanceM,
    summary,
    laps,
  });
  if (src.file) {
    await deps.activities.addFile(row.id, {
      kind: src.file.kind,
      key: src.file.key,
      bytes: src.file.body.length,
      sha256: await sha256Bytes(src.file.body),
    });
  }

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

  let plannedWorkoutId = row.plannedWorkoutId;
  if (!duplicateOf && src.plannedWorkoutId && src.plannedWorkoutId !== plannedWorkoutId) {
    await deps.activities.setPlanned(userId, row.id, src.plannedWorkoutId);
    plannedWorkoutId = src.plannedWorkoutId;
  }
  if (!duplicateOf && !plannedWorkoutId) {
    plannedWorkoutId = await matchPlan(deps, userId, row, localDate);
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

/** A new recording that starts (or ends) within this gap of an already linked one continues it. */
export const CONTINUATION_GAP_MS = 30 * 60 * 1000;

/**
 * Match to the plan: same local date and sport, not skipped. First a continuation — the watch was
 * stopped and restarted (19 km recorded as 17 + 2): a recording within 30 min of an activity
 * already linked to a candidate joins that workout. Otherwise the first workout (by order) that
 * has nothing linked yet.
 */
export async function matchPlan(
  deps: IngestDeps,
  userId: string,
  a: { id: string; sport: string; startAt: Date; endAt: Date },
  localDate: string,
): Promise<string | null> {
  const { id: activityId, sport } = a;
  if (sport === "other") return null;
  const day = await deps.docs.listByDate<PlannedWorkout>(
    userId,
    "planned_workout",
    localDate,
    localDate,
  );
  const candidates = day.map((d) => d.data).filter((w) => w.sport === sport && !w.skipped);
  const taken = await deps.activities.byPlanned(userId, candidates.map((w) => w.id));
  const near = (b: { startAt: Date; endAt: Date }) => {
    const after = a.startAt.getTime() - b.endAt.getTime(); // this one starts after b ended
    const before = b.startAt.getTime() - a.endAt.getTime(); // this one ended before b started
    return (after >= -60_000 && after <= CONTINUATION_GAP_MS) ||
      (before >= -60_000 && before <= CONTINUATION_GAP_MS);
  };
  const sorted = candidates.sort((x, y) => x.order - y.order);
  const pick =
    sorted.find((w) => (taken.get(w.id) ?? []).some((b) => b.id !== activityId && near(b))) ??
      sorted.find((w) => !taken.has(w.id));
  if (!pick) return null;
  await deps.activities.setPlanned(userId, activityId, pick.id);
  return pick.id;
}
