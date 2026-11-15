// Training analytics (FR-MCP-9, D30): load (volume + sRPE×min + HR load), time in zones,
// efficiency at a given HR. Per-activity numbers come from summary.analysis (domain/analysis.ts);
// zones are applied here with the current profile, so a threshold change needs no recompute.
import type { McpServer } from "@modelcontextprotocol/server";
import { z } from "zod";
import type { ActivityRow } from "../../db/activities.ts";
import { type Analysis, analysisOf } from "../../domain/analysis.ts";
import { IsoDate, type Profile } from "../../domain/entities.ts";
import { addDays, daysBetween, mondayOf } from "../../domain/time.ts";
import {
  distribute,
  edwardsTrimp,
  type Family,
  familyOf,
  hrZones,
  observedMaxHr,
  powerZones,
  threeSplit,
  zoneRanges,
  type ZoneSet,
} from "../../domain/zones.ts";
import { defaultTitle, type Summary } from "../../domain/healthkit.ts";
import type { McpContext } from "../server.ts";
import { defineTool, type ToolEnv, ToolError } from "../util.ts";

const Sport = z.enum(["run", "bike", "swim", "strength", "other"]);

/** Zones per family for this request (profile + observed max HR as the last resort). */
export class ZoneContext {
  private cache = new Map<string, ZoneSet | null>();
  constructor(
    private readonly ctx: McpContext,
    private readonly env: ToolEnv,
    private readonly profile: Profile,
    private readonly today: string,
  ) {}

  async hr(family: Family): Promise<ZoneSet | null> {
    const key = `hr:${family}`;
    if (!this.cache.has(key)) {
      let z = hrZones(this.profile, family);
      if (!z) {
        const maxima = await this.ctx.activities.hrMaxima(
          this.env.userId,
          addDays(this.today, -365),
          family,
        );
        z = hrZones(this.profile, family, observedMaxHr(maxima));
      }
      this.cache.set(key, z);
    }
    return this.cache.get(key)!;
  }

  power(family: Family): ZoneSet | null {
    return powerZones(this.profile, family);
  }
}

export function zoneView(z: ZoneSet) {
  return { basis: z.basis, confidence: z.confidence, ranges: zoneRanges(z) };
}

const pct = (
  part: number,
  total: number,
) => (total > 0 ? Math.round((part / total) * 1000) / 10 : 0);

function zoneRows(seconds: number[], z: ZoneSet | null) {
  const total = seconds.reduce((a, b) => a + b, 0);
  const ranges = z ? zoneRanges(z) : [];
  return seconds.map((sec, k) => ({
    zone: `Z${k + 1}`,
    range: ranges[k],
    sec,
    pct: pct(sec, total),
  }));
}

function polarization(seconds: number[], z: ZoneSet) {
  const t = threeSplit(seconds, z);
  const total = t.lowSec + t.midSec + t.highSec;
  return {
    lowPct: pct(t.lowSec, total),
    midPct: pct(t.midSec, total),
    highPct: pct(t.highSec, total),
  };
}

/** Activity view for analytics (`analysisOf` is null for manual entries and older summaries). */
interface Row {
  a: ActivityRow;
  s: Summary;
  an: Analysis | null;
}

async function rows(
  ctx: McpContext,
  userId: string,
  from: string,
  to: string,
  sport?: string,
): Promise<Row[]> {
  const list = await ctx.activities.list(userId, { from, to, sport, limit: 5000 });
  return list.map((a) => ({ a, s: a.summary as unknown as Summary, an: analysisOf(a.summary) }));
}

/** Bucket key: the date itself or its week's Monday. */
const bucketOf = (date: string, by: "day" | "week") => (by === "week" ? mondayOf(date) : date);

function buckets(from: string, to: string, by: "day" | "week"): string[] {
  const out: string[] = [];
  for (let d = bucketOf(from, by); d <= to; d = addDays(d, by === "week" ? 7 : 1)) out.push(d);
  return out;
}

const outdatedNote = (n: number) =>
  n > 0
    ? `${n} activities have no analysis yet (summary computed by an older version; a data migration fills it) — their time counts in volume but not in HR load / zones.`
    : null;

export function registerAnalyticsTools(server: McpServer, ctx: McpContext): void {
  defineTool(server, ctx, "get_load", {
    title: "Get training load",
    description:
      "Training load by week (or day): volume per sport (sessions, moving time, distance, elevation), sRPE load (RPE × minutes, only where the athlete gave RPE), HR load (Edwards TRIMP: minutes in HR zone k × k) and gym sessions/sets. Weekly view also compares the last full week with the 4 weeks before (ramp). Call when planning the next week or judging fatigue; for intensity split use get_zone_distribution. Default: the last 8 weeks including the current one (marked partial).",
    input: {
      from: IsoDate.optional(),
      to: IsoDate.optional(),
      groupBy: z.enum(["day", "week"]).optional(),
      sport: Sport.optional(),
    },
    readOnly: true,
  }, async (args, env) => {
    const now = await env.now();
    const by = args.groupBy ?? "week";
    const to = args.to ?? now.date;
    const from = args.from ?? addDays(mondayOf(to), -49);
    if (from > to) throw new ToolError("validation", "from must be ≤ to");
    if (daysBetween(from, to) > 400) {
      throw new ToolError("validation", "range is limited to ~13 months", "Narrow from/to.");
    }
    const zc = new ZoneContext(ctx, env, await env.profile(), now.date);
    const list = await rows(ctx, env.userId, from, to, args.sport);
    const lifts = args.sport && args.sport !== "strength"
      ? []
      : await ctx.strength.list(env.userId, { from, to, limit: 1000 });

    interface Agg {
      sessions: number;
      movingSec: number;
      distanceM: number;
      elevationGainM: number;
    }
    const empty = (): Agg => ({ sessions: 0, movingSec: 0, distanceM: 0, elevationGainM: 0 });
    const periods = new Map(
      buckets(from, to, by).map((k) => [k, {
        totals: empty(),
        bySport: {} as Record<string, Agg>,
        srpe: { load: 0, sessions: 0 },
        hrLoad: { trimp: 0, sessions: 0 },
        gym: { sessions: 0, setsDone: 0 },
      }]),
    );
    let outdated = 0;
    const zoneBases = new Set<string>();
    for (const { a, s, an } of list) {
      const p = periods.get(bucketOf(a.localDate, by));
      if (!p) continue;
      const moving = (s.movingSec as number | undefined) ?? a.durationSec;
      const add = (g: Agg) => {
        g.sessions++;
        g.movingSec += moving;
        // Trainer apps and treadmills report virtual distance and climbing: not summed.
        const virtual = s.distanceKind === "virtual" || s.indoor === true;
        g.distanceM += virtual ? 0 : (a.distanceM ?? 0);
        g.elevationGainM += virtual ? 0 : ((s.elevationGainM as number | null) ?? 0);
      };
      add(p.totals);
      add(p.bySport[a.sport] ??= empty());
      if (a.rpe) {
        p.srpe.load += a.rpe * (moving / 60);
        p.srpe.sessions++;
      }
      if (!an && s.detail === "full") outdated++;
      if (an?.hrHist) {
        const z = await zc.hr(familyOf(a.sport));
        const trimp = z ? edwardsTrimp(distribute(an.hrHist, z)) : null;
        if (z) zoneBases.add(`${familyOf(a.sport)}: ${z.basis}`);
        if (trimp !== null) {
          p.hrLoad.trimp += trimp;
          p.hrLoad.sessions++;
        }
      }
    }
    for (const l of lifts) {
      const p = periods.get(bucketOf(l.date, by));
      const done = l.sets.filter((x) => x.actual).length;
      if (!p || done === 0) continue;
      p.gym.sessions++;
      p.gym.setsDone += done;
    }
    const round = (g: Agg) => ({
      ...g,
      distanceM: Math.round(g.distanceM),
      elevationGainM: Math.round(g.elevationGainM),
      movingSec: Math.round(g.movingSec),
    });
    const out = [...periods.entries()].map(([start, p]) => {
      const end = by === "week" ? addDays(start, 6) : start;
      return {
        start,
        ...(by === "week" ? { end } : {}),
        ...(end >= now.date ? { partial: true } : {}), // the current week/day is not over yet
        totals: round(p.totals),
        bySport: Object.fromEntries(Object.entries(p.bySport).map(([k, v]) => [k, round(v)])),
        srpeLoad: p.srpe.sessions ? Math.round(p.srpe.load) : null,
        srpeSessions: p.srpe.sessions,
        hrLoad: p.hrLoad.sessions ? p.hrLoad.trimp : null,
        hrLoadSessions: p.hrLoad.sessions,
        gym: p.gym.sessions ? p.gym : undefined,
      };
    });

    // Ramp: last full week vs the mean of the 4 weeks before it.
    let ramp = null;
    if (by === "week") {
      const full = out.filter((w) => !w.partial);
      const last = full[full.length - 1];
      const prev = full.slice(-5, -1);
      if (last && prev.length === 4) {
        const m = (k: (w: typeof last) => number) => prev.reduce((a, w) => a + k(w), 0) / 4;
        const vs = (
          cur: number,
          base: number,
        ) => (base > 0 ? Math.round((cur / base - 1) * 100) : null);
        ramp = {
          week: last.start,
          movingSecVsPrev4wPct: vs(last.totals.movingSec, m((w) => w.totals.movingSec)),
          hrLoadVsPrev4wPct: vs(last.hrLoad ?? 0, m((w) => w.hrLoad ?? 0)),
        };
      }
    }
    return {
      range: { from, to },
      groupBy: by,
      periods: out,
      ramp,
      hrLoadBasis: [...zoneBases],
      notes: [outdatedNote(outdated)].filter(Boolean),
      howToRead: [
        "movingSec excludes standing (traffic lights, start line); distance and climbing of indoor rides/treadmill (virtual) are not summed.",
        "srpeLoad = RPE × moving minutes, only for sessions where the athlete gave RPE (srpeSessions) — usually sparse, do not read it as total load.",
        "hrLoad = Edwards TRIMP (minutes in HR zone k × k, 5-zone model; see hrLoadBasis for which zones). Comparable week to week for the same zones; changes in the zone model change it.",
        "ramp compares the last full week with the mean of the 4 weeks before it (+% = more).",
        "Duplicates (e.g. Strava copies) and recovery sessions (yoga, mobility) are excluded.",
      ],
    };
  });

  defineTool(server, ctx, "get_zone_distribution", {
    title: "Get zone distribution",
    description:
      "Time in HR zones (or bike power zones) over a period, per week and in total, with a 3-zone polarization split (low / moderate / high). Zones come from the profile (custom zones, else LTHR → Friel, max HR → % of max; bike power: FTP → Coggan) or, when the profile has none, from the max HR observed in the athlete's data (low confidence) — `zones.*.basis` says which. Use to check that easy work really is easy (base period) and how much intensity there was. Default: last 4 weeks plus the current one.",
    input: {
      from: IsoDate.optional(),
      to: IsoDate.optional(),
      sport: Sport.optional(),
      metric: z.enum(["hr", "power"]).optional(),
      groupBy: z.enum(["week", "total"]).optional(),
    },
    readOnly: true,
  }, async (args, env) => {
    const now = await env.now();
    const metric = args.metric ?? "hr";
    const to = args.to ?? now.date;
    const from = args.from ?? addDays(mondayOf(to), -28);
    if (from > to) throw new ToolError("validation", "from must be ≤ to");
    if (metric === "power" && args.sport && args.sport !== "bike") {
      throw new ToolError("validation", "power zones exist for bike only", "Use metric 'hr'.");
    }
    const zc = new ZoneContext(ctx, env, await env.profile(), now.date);
    const list = await rows(ctx, env.userId, from, to, metric === "power" ? "bike" : args.sport);
    const families = new Map<Family, ZoneSet | null>();
    const zonesOf = async (f: Family) => {
      if (!families.has(f)) families.set(f, metric === "hr" ? await zc.hr(f) : zc.power(f));
      return families.get(f)!;
    };

    let size = 0;
    const total: number[] = [];
    const bySport: Record<string, number[]> = {};
    const weeks = new Map<string, number[]>();
    let withData = 0;
    let outdated = 0;
    let noZones = 0;
    const add = (acc: number[], xs: number[]) => xs.forEach((x, i) => (acc[i] = (acc[i] ?? 0) + x));
    for (const { a, s, an } of list) {
      if (!an && s.detail === "full") outdated++;
      const h = metric === "hr" ? an?.hrHist : an?.powerHist;
      if (!h) continue;
      const zs = await zonesOf(familyOf(a.sport));
      if (!zs) {
        noZones++;
        continue;
      }
      const sec = distribute(h, zs);
      size = Math.max(size, sec.length);
      withData++;
      add(total, sec);
      add(bySport[a.sport] ??= [], sec);
      add(
        weeks.get(mondayOf(a.localDate)) ??
          weeks.set(mondayOf(a.localDate), []).get(mondayOf(a.localDate))!,
        sec,
      );
    }
    const pad = (xs: number[]) => Array.from({ length: size }, (_, i) => Math.round(xs[i] ?? 0));
    const ref = [...families.values()].find((z): z is ZoneSet => !!z) ?? null;
    if (!ref) {
      throw new ToolError(
        "no_zones",
        metric === "power"
          ? "No bike power zones: the profile has neither bike.ftp nor bike.powerZones."
          : "No HR zones: the profile has no hrZones/lthr/maxHr and there are too few activities with HR to estimate max HR.",
        metric === "power"
          ? "Ask the athlete for FTP and call update_profile {bike:{ftp}}."
          : "Ask the athlete for LTHR or max HR and call update_profile {run:{lthr}} or {run:{maxHr}}.",
      );
    }
    const totalSec = pad(total);
    return {
      metric,
      range: { from, to },
      zones: Object.fromEntries(
        [...families.entries()].filter(([, z]) => z).map(([f, z]) => [f, zoneView(z!)]),
      ),
      total: {
        sec: totalSec.reduce((a, b) => a + b, 0),
        zones: zoneRows(totalSec, ref),
        polarization: polarization(totalSec, ref),
      },
      ...(args.groupBy === "total" ? {} : {
        weeks: [...weeks.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([start, xs]) => {
          const sec = pad(xs);
          const sum = sec.reduce((a, b) => a + b, 0);
          return {
            start,
            sec: sum,
            pct: sec.map((x) => pct(x, sum)),
            ...polarization(sec, ref),
            ...(addDays(start, 6) >= now.date ? { partial: true } : {}),
          };
        }),
      }),
      bySport: Object.fromEntries(
        Object.entries(bySport).map(([k, xs]) => {
          const sec = pad(xs);
          const sum = sec.reduce((a, b) => a + b, 0);
          return [k, { sec: sum, pct: sec.map((x) => pct(x, sum)) }];
        }),
      ),
      coverage: { activities: list.length, withData, noZones, outdated },
      howToRead: [
        "Time is moving time with HR (or power) samples; each activity uses the zones of its family (bike zones for rides, run zones for everything else) — see zones.*.basis and confidence.",
        "polarization: low = Z1–Z2, moderate = Z3, high = Z4+ (power: Z4–Z7). A base period is mostly low; a lot of moderate time is the classic 'grey zone'.",
        "pct arrays in weeks/bySport are per zone, Z1 first. HR lags effort by 1–2 min, so short intervals show up lower than they were.",
        ...(ref.confidence === "low"
          ? [
            "Zones are a rough estimate from observed max HR — ask the athlete for LTHR (or a recent max HR) and store it with update_profile before drawing conclusions.",
          ]
          : []),
        ...[outdatedNote(outdated)].filter((x): x is string => !!x),
      ],
    };
  });

  defineTool(server, ctx, "get_efficiency_trend", {
    title: "Get efficiency trend",
    description:
      "The main base-period tracker: pace (grade-adjusted) or power the athlete holds at the same HR, per workout and as a trend. Uses only steady stretches (continuous moving, HR ±6 bpm, ≥5 min) whose HR is inside the corridor; default corridor = HR zone 2 of the athlete's zones. Rising power / faster pace at the same HR = aerobic progress. Run: metric pace_at_hr (GAP; treadmill excluded) or power_at_hr; bike: power_at_hr. Default: last 12 weeks.",
    input: {
      sport: z.enum(["run", "bike"]),
      metric: z.enum(["pace_at_hr", "power_at_hr"]),
      hrLow: z.number().int().min(60).max(220).optional(),
      hrHigh: z.number().int().min(60).max(220).optional(),
      from: IsoDate.optional(),
      to: IsoDate.optional(),
    },
    readOnly: true,
  }, async (args, env) => {
    if (args.sport === "bike" && args.metric !== "power_at_hr") {
      throw new ToolError(
        "validation",
        "bike supports power_at_hr only",
        "Outdoor speed depends on wind and grade.",
      );
    }
    const now = await env.now();
    const to = args.to ?? now.date;
    const from = args.from ?? addDays(to, -83);
    const zc = new ZoneContext(ctx, env, await env.profile(), now.date);
    let lo = args.hrLow;
    let hi = args.hrHigh;
    let corridorBasis = "given";
    if (lo === undefined || hi === undefined) {
      const z = await zc.hr(args.sport);
      if (!z || z.bounds.length < 2) {
        throw new ToolError(
          "no_zones",
          "No HR zones to pick a default corridor.",
          "Pass hrLow/hrHigh (e.g. the athlete's easy-run HR range), or store LTHR/max HR with update_profile.",
        );
      }
      lo ??= z.bounds[0];
      hi ??= z.bounds[1] - 1;
      corridorBasis = `zone 2 of ${z.basis} (confidence ${z.confidence})`;
    }
    if (lo > hi) throw new ToolError("validation", "hrLow must be ≤ hrHigh");
    const midHr = (lo + hi) / 2;
    const list = await rows(ctx, env.userId, from, to, args.sport);
    const points = [];
    let outdated = 0;
    for (const { a, s, an } of list) {
      if (!an && s.detail === "full") outdated++;
      if (!an) continue;
      if (args.metric === "pace_at_hr" && a.subSport === "treadmill") continue;
      let sec = 0;
      let hrSum = 0;
      let outSum = 0;
      let gap = true;
      for (const g of an.steady) {
        if (g.hr < lo || g.hr > hi) continue;
        const out = args.metric === "power_at_hr" ? g.power : (g.gapSpeed ?? g.speed);
        if (!out) continue;
        if (args.metric === "pace_at_hr" && g.gapSpeed === null) gap = false;
        sec += g.durationSec;
        hrSum += g.hr * g.durationSec;
        outSum += out * g.durationSec;
      }
      if (sec < 300) continue;
      const hr = hrSum / sec;
      const out = outSum / sec;
      const atMid = out * (midHr / hr);
      const weather = s.weather as { tempC?: number | null } | null;
      points.push({
        date: a.localDate,
        activityId: a.id,
        title: a.title ?? defaultTitle(s),
        minutes: Math.round(sec / 60),
        hr: Math.round(hr * 10) / 10,
        ...(args.metric === "pace_at_hr"
          ? {
            paceSecPerKm: Math.round(1000 / out),
            paceAtMidHrSecPerKm: Math.round(1000 / atMid),
            gradeAdjusted: gap,
          }
          : { powerW: Math.round(out), powerAtMidHrW: Math.round(atMid) }),
        efficiency: Math.round((args.metric === "pace_at_hr" ? out * 60 : out) / hr * 1000) / 1000,
        tempC: weather?.tempC ?? null,
        _v: atMid,
        _w: sec,
      });
    }
    points.sort((x, y) => x.date.localeCompare(y.date));

    // Weighted least squares of output-at-mid-HR over days.
    let trend = null;
    if (points.length >= 3) {
      const t0 = points[0].date;
      const xs = points.map((p) => daysBetween(t0, p.date));
      const ws = points.map((p) => p._w);
      const ys = points.map((p) => p._v);
      const W = ws.reduce((a, b) => a + b, 0);
      const mx = xs.reduce((a, x, i) => a + x * ws[i], 0) / W;
      const my = ys.reduce((a, y, i) => a + y * ws[i], 0) / W;
      const sxx = xs.reduce((a, x, i) => a + ws[i] * (x - mx) ** 2, 0);
      const sxy = xs.reduce((a, x, i) => a + ws[i] * (x - mx) * (ys[i] - my), 0);
      const spanDays = xs[xs.length - 1];
      if (sxx > 0 && spanDays >= 14) {
        const slope = sxy / sxx; // output units per day
        const startV = my + slope * (0 - mx);
        const endV = my + slope * (spanDays - mx);
        trend = args.metric === "pace_at_hr"
          ? {
            paceAtMidHrStartSecPerKm: Math.round(1000 / startV),
            paceAtMidHrEndSecPerKm: Math.round(1000 / endV),
            secPerKmPer4Weeks:
              Math.round((1000 / (my + slope * 14) - 1000 / (my - slope * 14)) * 10) / 10,
          }
          : {
            powerAtMidHrStartW: Math.round(startV),
            powerAtMidHrEndW: Math.round(endV),
            wattsPer4Weeks: Math.round(slope * 28 * 10) / 10,
          };
      }
    }
    const n = points.length;
    const spanDays = n ? daysBetween(points[0].date, points[n - 1].date) : 0;
    return {
      sport: args.sport,
      metric: args.metric,
      corridor: { hrLow: lo, hrHigh: hi, basis: corridorBasis },
      range: { from, to },
      points: points.map(({ _v: _a, _w: _b, ...p }) => p),
      trend,
      confidence: n >= 12 && spanDays >= 42 ? "high" : n >= 6 && spanDays >= 21 ? "medium" : "low",
      notes: [outdatedNote(outdated)].filter(Boolean),
      howToRead: [
        "Only steady stretches inside the HR corridor count (minutes = how much of the workout); workouts with < 5 such minutes are skipped.",
        args.metric === "pace_at_hr"
          ? "paceSecPerKm is grade-adjusted (GAP) when the route has altitude (gradeAdjusted); paceAtMidHr rescales to the corridor's middle HR (assumes speed ∝ HR inside a narrow corridor) so workouts at slightly different HR compare. Lower = better."
          : "powerAtMidHr rescales to the corridor's middle HR (assumes power ∝ HR inside a narrow corridor). Higher = better.",
        "efficiency = output per bpm (run: metres per minute per bpm; power: W per bpm).",
        "trend = weighted linear fit over the period (weights = steady minutes). Not every dip is lost fitness: heat raises HR at the same output; snow, ice, winter clothing and cold (tempC) slow pace and running power at the same HR; so do poor sleep, illness and fatigue. Compare like with like (season, surface) before calling it a regression.",
      ],
    };
  });
}

/** What get_activity shows instead of the stored histograms: zones applied, GAP, decoupling. */
export async function analysisView(an: Analysis, sport: string, zc: ZoneContext) {
  const f = familyOf(sport);
  const hz = an.hrHist ? await zc.hr(f) : null;
  const pz = an.powerHist ? zc.power(f) : null;
  const zoneBlock = (h: NonNullable<Analysis["hrHist"]>, z: ZoneSet) => {
    const sec = distribute(h, z);
    return { ...zoneView(z), sec, polarization: polarization(sec, z) };
  };
  return {
    gapSecPerKm: an.gapSecPerKm ?? undefined,
    gapBasis: an.gapBasis ?? undefined,
    decoupling: an.decoupling,
    steadyMin: Math.round(an.steady.reduce((a, g) => a + g.durationSec, 0) / 60),
    steady: an.steady,
    zones: {
      hr: an.hrHist && hz ? zoneBlock(an.hrHist, hz) : null,
      power: an.powerHist && pz ? zoneBlock(an.powerHist, pz) : null,
    },
  };
}
