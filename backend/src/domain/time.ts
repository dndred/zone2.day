// Dates in the athlete's world (docs/03-data-model.md §1.1): plan dates are local calendar dates
// in the *effective* time zone of that date = travel period covering it, else home zone.

export const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

export interface Travel {
  from: string;
  to: string;
  timezone: string;
  note?: string;
}

export interface TimeProfile {
  timezone: string;
  travel?: Travel[];
}

export function isValidTimeZone(tz: string): boolean {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}

export function isValidDate(s: string): boolean {
  if (!ISO_DATE.test(s)) return false;
  const d = new Date(`${s}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === s;
}

export interface LocalNow {
  date: string;
  time: string;
  weekday: string;
}

export function localParts(at: Date, timeZone: string): LocalNow {
  const f = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    weekday: "short",
    hour12: false,
  });
  const p = Object.fromEntries(f.formatToParts(at).map((x) => [x.type, x.value]));
  const hour = p.hour === "24" ? "00" : p.hour;
  return { date: `${p.year}-${p.month}-${p.day}`, time: `${hour}:${p.minute}`, weekday: p.weekday };
}

export function effectiveTimezone(profile: TimeProfile, date: string): string {
  const trip = (profile.travel ?? []).find((t) => t.from <= date && date <= t.to);
  return trip?.timezone ?? profile.timezone;
}

export interface AthleteNow extends LocalNow {
  timezone: string;
  homeTimezone: string;
  traveling: boolean;
}

export function athleteNow(profile: TimeProfile, at: Date): AthleteNow {
  const home = localParts(at, profile.timezone);
  const tz = effectiveTimezone(profile, home.date);
  const local = tz === profile.timezone ? home : localParts(at, tz);
  return {
    ...local,
    timezone: tz,
    homeTimezone: profile.timezone,
    traveling: tz !== profile.timezone,
  };
}

export function addDays(date: string, days: number): string {
  const d = new Date(`${date}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

/** Monday of the ISO week containing `date`. */
export function mondayOf(date: string): string {
  const d = new Date(`${date}T00:00:00Z`);
  const dow = (d.getUTCDay() + 6) % 7; // Monday = 0
  return addDays(date, -dow);
}

export function daysBetween(from: string, to: string): number {
  return Math.round(
    (new Date(`${to}T00:00:00Z`).getTime() - new Date(`${from}T00:00:00Z`).getTime()) / 86_400_000,
  );
}

/** Wall-clock "YYYY-MM-DDTHH:MM[:SS]" in `timeZone` → instant (minute precision for the offset). */
export function zonedToUtc(local: string, timeZone: string): Date {
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?$/.exec(local);
  if (!m) throw new Error(`expected local time YYYY-MM-DDTHH:MM, got ${local}`);
  const [y, mo, d, h, mi, s] = m.slice(1).map((x) => Number(x ?? 0));
  const want = Date.UTC(y, mo - 1, d, h, mi);
  let guess = want;
  // Two passes settle the offset, also next to a DST switch.
  for (let i = 0; i < 2; i++) {
    const p = localParts(new Date(guess), timeZone);
    const seen = Date.parse(`${p.date}T${p.time}:00Z`);
    guess += want - seen;
  }
  return new Date(guess + s * 1000);
}
