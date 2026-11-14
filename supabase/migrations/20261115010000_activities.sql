-- zone2.day: completed activities (typed tables: high volume, SQL analytics) + their files,
-- the first-party iOS OAuth client and the private Storage bucket for raw files.

create table zone2.activities (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references zone2.users(id) on delete cascade,
  source text not null,                       -- healthkit | intervals | fit_upload | gpx_upload | manual
  source_id text not null,                    -- HKWorkout.uuid, intervals id, …
  source_app text,                            -- e.g. "Andrei’s Apple Watch", "Strava"
  sport text not null,                        -- run | bike | swim | strength | other
  sub_sport text,                             -- indoor_bike, pool, open_water, treadmill, walk, hike…
  activity_type int,                          -- raw HKWorkoutActivityType
  start_at timestamptz not null,
  end_at timestamptz not null,
  timezone text,                              -- IANA zone the workout was recorded in
  local_date date not null,                   -- athlete-local start date (for plan matching)
  duration_sec int not null,
  distance_m double precision,
  summary jsonb not null default '{}',
  laps jsonb not null default '[]',
  planned_workout_id uuid,                    -- matched planned workout (document id)
  title text,
  tags text[] not null default '{}',
  athlete_notes text,
  coach_notes text,
  rpe smallint check (rpe between 1 and 10),
  official jsonb,
  grade text,
  duplicate_of uuid references zone2.activities(id),  -- e.g. Strava's copy of an indoor ride
  version int not null default 1,
  deleted_at timestamptz,
  deleted_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, source, source_id)
);
create index activities_user_date_idx on zone2.activities (user_id, local_date desc) where deleted_at is null;
create index activities_planned_idx on zone2.activities (user_id, planned_workout_id) where deleted_at is null;

create table zone2.activity_files (
  id uuid primary key default gen_random_uuid(),
  activity_id uuid not null references zone2.activities(id) on delete cascade,
  kind text not null check (kind in ('healthkit_dump', 'fit_original', 'fit_generated', 'streams')),
  storage_key text not null,
  bytes int not null,
  sha256 text not null,
  created_at timestamptz not null default now(),
  unique (activity_id, kind)
);

-- First-party iOS app: public client, PKCE, custom-scheme redirect.
insert into zone2.oauth_clients (client_id, client_secret_hash, client_name, redirect_uris, token_endpoint_auth_method, kind)
values ('zone2-ios', null, 'zone2.day iOS', array['zone2://oauth/callback'], 'none', 'first_party')
on conflict (client_id) do nothing;

-- Private bucket for raw files (only on Supabase; plain Postgres in tests has no storage schema).
do $$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    insert into storage.buckets (id, name, public) values ('activity-files', 'activity-files', false)
    on conflict (id) do nothing;
  end if;
end $$;

do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke all on all tables in schema zone2 from %I', r);
    end if;
  end loop;
end $$;
