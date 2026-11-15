// Daily health metrics from Apple Health (resting HR, HRV SDNN, sleep, respiratory rate, wrist
// temperature, weight, VO2max) against the athlete's own 28-day baseline.
import type { McpServer } from "@modelcontextprotocol/server";
import { IsoDate } from "../../domain/entities.ts";
import { BASELINE_DAYS, compareDays } from "../../domain/readiness.ts";
import { addDays, daysBetween } from "../../domain/time.ts";
import type { McpContext } from "../server.ts";
import { defineTool, ToolError } from "../util.ts";

export const HEALTH_HOW_TO_READ = [
  "Each metric: value, avg7 (7 days ending that day), baseline (mean of the 28 days before, needs ≥14), delta = value − baseline, z = delta in standard deviations.",
  "HRV is SDNN (Apple), not RMSSD: compare only with this athlete's own history. Apple samples it a few times a day, mostly asleep — single days are noisy, read avg7 vs baseline (flag hrv_7d_low).",
  "flags: hrv_7d_low (7-day HRV mean > 1 sd below baseline), hrv_very_low_today (z ≤ −2), resting_hr_up (≥ +5 bpm), wrist_temp_up (≥ +0.5 °C), respiratory_rate_up (≥ +1.5/min), short_sleep (< 6 h asleep). Several together (temp + resting HR + respiratory rate) often precede illness: ease off and ask how the athlete feels.",
  "sleep is the night ending that morning (date = wake-up day); minutes asleep exclude awake time; stages come from the watch and are estimates.",
  "missing: true = no data that day (watch not worn, or not synced yet — the phone resends the last week on every sync).",
];

export function registerHealthTools(server: McpServer, ctx: McpContext): void {
  defineTool(server, ctx, "get_daily_metrics", {
    title: "Get daily health metrics",
    description:
      "Recovery data per day from Apple Health: resting HR, HRV (SDNN), sleep (asleep/deep/REM/core/awake minutes, bed times), respiratory rate, sleeping wrist temperature, weight, VO2max — each against the athlete's own 28-day baseline, with flags (low HRV trend, raised resting HR or temperature, short sleep). Read before planning hard sessions or when the athlete feels off; get_context already shows the last 3 days. Default: the last 14 days.",
    input: {
      from: IsoDate.optional(),
      to: IsoDate.optional(),
    },
    readOnly: true,
  }, async (args, env) => {
    const now = await env.now();
    const to = args.to ?? now.date;
    const from = args.from ?? addDays(to, -13);
    if (from > to) throw new ToolError("validation", "from must be ≤ to");
    if (daysBetween(from, to) > 120) {
      throw new ToolError("validation", "range is limited to 120 days", "Narrow from/to.");
    }
    const rows = await ctx.metrics.range(env.userId, addDays(from, -BASELINE_DAYS), to);
    const days = compareDays(rows, from, to);
    const present = days.filter((d) => !("missing" in d));
    return {
      range: { from, to },
      days,
      coverage: { days: days.length, withData: present.length },
      ...(rows.length === 0
        ? {
          notConnected:
            "No health data yet: the iPhone app sends it after the athlete allows Health access (Profile → Health) and syncs.",
        }
        : {}),
      howToRead: HEALTH_HOW_TO_READ,
    };
  });
}

/** Last `n` days for get_context (compact: values, deltas, flags). */
export async function recentRecovery(ctx: McpContext, userId: string, today: string, n = 3) {
  const from = addDays(today, -(n - 1));
  const rows = await ctx.metrics.range(userId, addDays(from, -BASELINE_DAYS), today);
  if (rows.length === 0) return null;
  return compareDays(rows, from, today).map((d) =>
    "missing" in d ? d : {
      date: d.date,
      restingHr: d.restingHr ? { value: d.restingHr.value, delta: d.restingHr.delta } : null,
      hrvSdnnMs: d.hrvSdnnMs
        ? { value: d.hrvSdnnMs.value, avg7: d.hrvSdnnMs.avg7, baseline: d.hrvSdnnMs.baseline }
        : null,
      asleepMin: d.sleep?.asleepMin ?? null,
      flags: d.flags,
    }
  );
}
