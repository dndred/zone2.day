// revert_change for changes stored outside documents (activities, strength log). Documents are
// reverted generically by DocumentStore.revert (write `before` back); these need their own undo.
import { type ActivityAnnotations, ANNOTATION_KEYS } from "../../db/activities.ts";
import type { ChangeEntry, ChangeMeta } from "../../db/documents.ts";
import type { PlannedWorkout } from "../../domain/entities.ts";
import { logView } from "../../domain/strength.ts";
import type { McpContext } from "../server.ts";
import { ToolError } from "../util.ts";

export interface ExternalRevert {
  newChangeId: string;
  op: "create" | "update" | "delete";
  warnings: string[];
}

const cannot = (entry: ChangeEntry, hint: string) =>
  new ToolError(
    "not_revertable",
    `${entry.entity} ${entry.op} by ${entry.tool} cannot be reverted with revert_change`,
    hint,
  );

export async function revertExternal(
  ctx: McpContext,
  userId: string,
  entry: ChangeEntry,
  meta: ChangeMeta,
): Promise<ExternalRevert> {
  const log = (op: ExternalRevert["op"], before: unknown, after: unknown) =>
    ctx.docs.logExternal(userId, meta, entry.entity, entry.entityId, op, before, after);

  const entity: string = entry.entity;
  if (entity === "activity") {
    const before = entry.before as { plannedWorkoutId?: string | null } | null;
    if (entry.op === "create") {
      const ok = await ctx.activities.softDelete(userId, entry.entityId, "reverted");
      if (!ok) throw new ToolError("conflict", `activity ${entry.entityId} is already deleted`);
      return { newChangeId: await log("delete", entry.after, null), op: "delete", warnings: [] };
    }
    if (entry.op === "delete") {
      const r = await ctx.activities.restore(userId, entry.entityId);
      if (!r.restored) {
        throw new ToolError("conflict", `activity ${entry.entityId} is not deleted`);
      }
      const row = (await ctx.activities.get(userId, entry.entityId))!;
      return {
        newChangeId: await log("create", null, {
          ...(entry.before as object),
          plannedWorkoutId: row.plannedWorkoutId,
        }),
        op: "create",
        warnings: [],
      };
    }
    if (before && ANNOTATION_KEYS.some((k) => k in before)) {
      // Notes, title, rpe, tags (update_activity): write the previous values back.
      const cur = await ctx.activities.get(userId, entry.entityId);
      if (!cur) throw new ToolError("not_found", `activity ${entry.entityId} not found`);
      const prev = before as ActivityAnnotations;
      const now: Record<string, unknown> = {};
      for (const k of Object.keys(prev) as (keyof ActivityAnnotations)[]) now[k] = cur[k];
      await ctx.activities.setAnnotations(userId, cur.id, prev);
      return { newChangeId: await log("update", now, prev), op: "update", warnings: [] };
    }
    if (before && "plannedWorkoutId" in before) {
      // A link change (link_activities): put the previous link back.
      const target = before.plannedWorkoutId ?? null;
      const cur = await ctx.activities.get(userId, entry.entityId);
      if (!cur) throw new ToolError("not_found", `activity ${entry.entityId} not found`);
      if (target) {
        const plan = await ctx.docs.get<PlannedWorkout>(userId, "planned_workout", target);
        if (!plan) throw new ToolError("not_found", `planned workout ${target} no longer exists`);
      }
      await ctx.activities.relink(userId, [{ id: cur.id, plannedId: target }]);
      return {
        newChangeId: await log(
          "update",
          { plannedWorkoutId: cur.plannedWorkoutId },
          { plannedWorkoutId: target },
        ),
        op: "update",
        warnings: [],
      };
    }
    throw cannot(entry, "A re-import refreshes the activity from its file; nothing to undo.");
  }

  if (entity === "strength_session") {
    if (entry.op === "create" || entry.op === "delete") {
      const deleting = entry.op === "create";
      const ok = await ctx.strength.setDeleted(userId, entry.entityId, deleting, ctx.now());
      if (!ok) {
        throw new ToolError(
          "conflict",
          `strength session ${entry.entityId} is ${deleting ? "already deleted" : "not deleted"}`,
        );
      }
      const [s] = await ctx.strength.getMany(userId, [entry.entityId], { includeDeleted: true });
      const view = logView(s);
      return deleting
        ? { newChangeId: await log("delete", view, null), op: "delete", warnings: [] }
        : { newChangeId: await log("create", null, view), op: "create", warnings: [] };
    }
    throw cannot(entry, "Fix the sets with update_strength_log (ids from get_strength_log).");
  }

  throw cannot(entry, "Merged exercises cannot be split automatically.");
}
