-- zone2.day: plan-like entities as validated JSONB documents + change log + sync feed.
-- Entities: profile, week, planned_workout, event, journal, notebook_page (docs/03-data-model.md, D35).
-- Validation lives in backend/src/domain (Zod). High-volume data (activities, streams, sets,
-- metrics) gets typed tables in later migrations.

create table zone2.documents (
  user_id uuid not null references zone2.users(id) on delete cascade,
  entity text not null check (entity in ('profile', 'week', 'planned_workout', 'event', 'journal', 'notebook_page')),
  id text not null,                         -- uuid, or natural key: week start date, notebook slug, 'profile'
  data jsonb not null,
  version int not null default 1,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, entity, id)
);
create index documents_date_idx on zone2.documents (user_id, entity, (data ->> 'date'))
  where deleted_at is null;

create table zone2.change_log (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references zone2.users(id) on delete cascade,
  at timestamptz not null default now(),
  actor text not null,                      -- ai:<client name> | user:app | system:<job>
  tool text not null,                       -- MCP tool or endpoint
  entity text not null,
  entity_id text not null,
  op text not null check (op in ('create', 'update', 'delete')),
  before jsonb,
  after jsonb,
  why text,
  reverted_by uuid references zone2.change_log(id)
);
create index change_log_user_at_idx on zone2.change_log (user_id, at desc);
create index change_log_entity_idx on zone2.change_log (user_id, entity, entity_id, at desc);

create table zone2.sync_feed (
  seq bigserial primary key,
  user_id uuid not null references zone2.users(id) on delete cascade,
  entity text not null,
  entity_id text not null,
  version int not null,
  op text not null check (op in ('upsert', 'delete')),
  at timestamptz not null default now()
);
create index sync_feed_user_seq_idx on zone2.sync_feed (user_id, seq);

do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke all on all tables in schema zone2 from %I', r);
      execute format('revoke all on all sequences in schema zone2 from %I', r);
    end if;
  end loop;
end $$;
