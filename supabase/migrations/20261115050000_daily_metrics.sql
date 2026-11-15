-- zone2.day: daily health metrics from Apple Health (docs/03-data-model.md §2.7, docs/05-sync.md §7).
-- The phone aggregates each athlete-local day from HealthKit and sends it again whenever the day
-- may have changed (late watch syncs): the row is replaced as a whole.

create table zone2.daily_metrics (
  user_id uuid not null references zone2.users(id) on delete cascade,
  date date not null,                          -- athlete-local date; sleep = the night ending that morning
  resting_hr real,                             -- bpm, Apple's daily resting HR
  hrv_sdnn_ms real,                            -- mean of the day's SDNN samples (Apple stores SDNN, not RMSSD)
  hrv_samples smallint,
  sleep jsonb,                                 -- {asleepMin, deepMin, remMin, coreMin, awakeMin, inBedStart, inBedEnd, source}
  respiratory_rate real,                       -- breaths/min, mean of the day's samples (mostly during sleep)
  wrist_temp_c real,                           -- sleeping wrist temperature, absolute °C
  weight_kg real,
  vo2max real,                                 -- ml/kg/min, Apple's estimate
  device_id text,
  updated_at timestamptz not null default now(),
  primary key (user_id, date)
);

do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke all on all tables in schema zone2 from %I', r);
    end if;
  end loop;
end $$;
