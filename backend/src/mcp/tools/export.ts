// export_workout: planned workout → file for another app (.zwo for MyWhoosh).
import type { McpServer } from "@modelcontextprotocol/server";
import { z } from "zod";
import type { PlannedWorkout, Profile } from "../../domain/entities.ts";
import { buildZwo, ZwoError } from "../../domain/zwo.ts";
import type { McpContext } from "../server.ts";
import { defineTool, ToolError } from "../util.ts";

/** Long enough to AirDrop the file to the Mac later the same day. */
export const EXPORT_TTL_SEC = 24 * 3600;

/** FTP the .zwo fractions are relative to: explicit > bike.mywhooshFtp > bike.ftp (mid of a range). */
export function exportFtp(
  profile: Profile,
  explicit?: number,
): { ftp: number; source: string } | null {
  if (explicit) return { ftp: explicit, source: "ftpW argument" };
  const mw = profile.bike?.mywhooshFtp;
  if (mw) return { ftp: mw, source: "bike.mywhooshFtp" };
  const ftp = profile.bike?.ftp;
  if (!ftp) return null;
  return {
    ftp: Math.round(typeof ftp === "number" ? ftp : (ftp.low + ftp.high) / 2),
    source: "bike.ftp",
  };
}

export function registerExportTools(server: McpServer, ctx: McpContext): void {
  defineTool(server, ctx, "export_workout", {
    title: "Export workout file",
    description:
      "Planned bike workout → .zwo file for MyWhoosh (ERG). Call when the athlete rides a trainer session (execution 'mywhoosh') and asks for the file; give them the url (valid 24 h) — they AirDrop it to the Mac and import it in MyWhoosh's workout builder. Only for workouts with power targets; steps must have time durations. .zwo stores power as a fraction of FTP, so the file is built against the FTP set in MyWhoosh: bike.mywhooshFtp from the profile, else bike.ftp; if neither is set, ask the athlete which FTP MyWhoosh shows and pass it as ftpW (save it with update_profile bike.mywhooshFtp so you need not ask again). Warmup/cooldown power ranges become ramps, other steps hold the middle of the range, steps without power are free ride. Read-only for the plan; `xml` is the file content for clients that save files themselves.",
    input: {
      plannedWorkoutId: z.uuid(),
      format: z.enum(["zwo"]).default("zwo"),
      ftpW: z.number().int().min(50).max(600).optional().describe(
        "FTP set in MyWhoosh, W. Only when the profile has neither bike.mywhooshFtp nor bike.ftp, or the athlete says MyWhoosh shows a different one",
      ),
    },
    readOnly: true,
  }, async ({ plannedWorkoutId, ftpW }, env) => {
    const doc = await ctx.docs.get<PlannedWorkout>(env.userId, "planned_workout", plannedWorkoutId);
    if (!doc) throw new ToolError("not_found", `planned workout ${plannedWorkoutId} not found`);
    const w = doc.data;
    if (w.sport !== "bike") {
      throw new ToolError("unsupported", `.zwo is for bike workouts; this one is ${w.sport}`);
    }
    if (!w.structure) throw new ToolError("unsupported", "workout has no structure to export");
    const profile = await env.profile();
    const ftp = exportFtp(profile, ftpW);
    if (!ftp) {
      throw new ToolError(
        "ftp_required",
        ".zwo stores power as a fraction of FTP, and the profile has no bike FTP",
        "Ask the athlete which FTP is set in MyWhoosh, pass it as ftpW and save it with update_profile({bike:{mywhooshFtp}})",
      );
    }
    let zwo;
    try {
      zwo = buildZwo(w, profile, ftp.ftp);
    } catch (err) {
      if (err instanceof ZwoError) throw new ToolError("unsupported", err.message, err.hint);
      throw err;
    }
    const warnings = [...zwo.warnings];
    const bikeFtp = exportFtp({ ...profile, bike: { ...profile.bike, mywhooshFtp: undefined } });
    if (bikeFtp && bikeFtp.ftp !== ftp.ftp) {
      warnings.push(
        `file built for FTP ${ftp.ftp} W (${ftp.source}) but bike.ftp is ${bikeFtp.ftp} W: %-targets are resolved from bike.ftp, then scaled to ${ftp.ftp} W so MyWhoosh shows the planned watts`,
      );
    }

    const file = `${w.date}-${w.sport}-v${doc.version}.zwo`;
    const key = `${env.userId}/exports/${w.id}/${file}`;
    await ctx.blobs.put(key, new TextEncoder().encode(zwo.xml), "application/xml");
    const url = await ctx.blobs.signedUrl(key, EXPORT_TTL_SEC);
    return {
      format: "zwo",
      filename: file,
      url: `${url}${url.includes("?") ? "&" : "?"}download=${encodeURIComponent(file)}`,
      expiresAt: new Date(ctx.now().getTime() + EXPORT_TTL_SEC * 1000).toISOString(),
      workout: { id: w.id, version: doc.version, date: w.date, title: w.title },
      ftpW: ftp.ftp,
      ftpSource: ftp.source,
      durationSec: zwo.durationSec,
      warnings,
      howToRead:
        `Power in the file is relative to FTP ${ftp.ftp} W: tell the athlete to check that MyWhoosh has exactly this FTP, otherwise ERG watts scale with it.`,
      xml: zwo.xml,
    };
  });
}
