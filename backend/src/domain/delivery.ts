// Delivery state of a planned workout to the watch, from device reports (pure).
import type { DeliveryRow, DeviceRow } from "../db/deliveries.ts";

export type DeliveryState =
  /** On the watch with the current version. */
  | "on_watch"
  /** An older version is on the watch: the phone has not pulled the latest change yet. */
  | "outdated"
  /** Not on the watch (not delivered yet, or removed). */
  | "not_on_watch";

export interface Delivery {
  state: DeliveryState;
  at?: string;
  device?: string;
  warnings?: string[];
  /** Why it cannot be on the watch right now (device-level problem). */
  problem?: string;
}

/** Only for future/today workouts the watch should run; undefined otherwise. */
export function deliveryOf(
  w: { id: string; date: string; execution: string },
  version: number,
  status: string,
  today: string,
  rows: DeliveryRow[],
  devices: DeviceRow[],
): Delivery | undefined {
  if (w.execution !== "workoutkit" || status !== "planned" || w.date < today) return undefined;
  const mine = rows.filter((r) => r.plannedWorkoutId === w.id && r.stage === "scheduled_watch")
    .sort((a, b) => b.version - a.version);
  const name = (id: string) => devices.find((d) => d.id === id)?.name ?? id;
  const current = mine.find((r) => r.version === version);
  if (current) {
    return {
      state: "on_watch",
      at: current.at.toISOString(),
      device: name(current.deviceId),
      warnings: current.warnings.length ? current.warnings : undefined,
    };
  }
  if (mine[0]) {
    return { state: "outdated", at: mine[0].at.toISOString(), device: name(mine[0].deviceId) };
  }
  const problem = devices.find((d) => d.watchError)?.watchError ?? undefined;
  return { state: "not_on_watch", problem };
}
