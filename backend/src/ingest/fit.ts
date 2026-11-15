// FIT activity file (e.g. a MyWhoosh ride export) → activity. The original is stored byte for
// byte as fit_original; streams and recomputed summaries are decoded from it on demand.
import { sha256Bytes } from "../auth/crypto.ts";
import { fitToDump } from "../domain/fit.ts";
import { type IngestDeps, type IngestResult, saveDump } from "./healthkit.ts";

/** Same file → same activity: re-importing is idempotent. */
export const fitSourceId = async (bytes: Uint8Array) => `sha256:${await sha256Bytes(bytes)}`;

export async function ingestFit(
  deps: IngestDeps,
  userId: string,
  bytes: Uint8Array,
  opts: { storeOriginal?: boolean; plannedWorkoutId?: string; now?: Date } = {},
): Promise<IngestResult> {
  const sourceId = await fitSourceId(bytes);
  const dump = fitToDump(bytes, sourceId, opts.now ?? new Date());
  return await saveDump(deps, userId, dump, {
    source: "fit_upload",
    sourceId,
    plannedWorkoutId: opts.plannedWorkoutId,
    file: (opts.storeOriginal ?? true)
      ? {
        kind: "fit_original",
        key: `${userId}/fit/${sourceId.slice(7)}.fit`,
        body: bytes,
        contentType: "application/vnd.ant.fit",
      }
      : undefined,
  });
}
