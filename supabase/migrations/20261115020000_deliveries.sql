-- zone2.day: devices and workout delivery to the watch (docs/03-data-model.md §2.12, docs/05-sync.md §5).
-- The phone reports a snapshot "these planned workouts are on the watch now" after each reconcile;
-- the coach reads it through get_delivery_status / get_plan.

create table zone2.devices (
  user_id uuid not null references zone2.users(id) on delete cascade,
  id text not null,                           -- client-generated, stable per app install
  name text,
  model text,
  app_version text,
  last_seen_at timestamptz not null default now(),
  last_pull_at timestamptz,                   -- last successful GET /v1/sync on the device
  sync_cursor text,
  watch_error text,                           -- e.g. "not authorized", "no watch"
  watch_reported_at timestamptz,
  primary key (user_id, id)
);

create table zone2.deliveries (
  user_id uuid not null references zone2.users(id) on delete cascade,
  planned_workout_id text not null,
  device_id text not null,
  version int not null,                       -- planned_workout version that is on the watch
  stage text not null check (stage in ('scheduled_watch', 'removed')),
  date date not null,
  warnings jsonb not null default '[]',
  at timestamptz not null default now(),
  primary key (user_id, planned_workout_id, device_id),
  foreign key (user_id, device_id) references zone2.devices (user_id, id) on delete cascade
);
create index deliveries_user_date_idx on zone2.deliveries (user_id, date);

do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke all on all tables in schema zone2 from %I', r);
    end if;
  end loop;
end $$;
