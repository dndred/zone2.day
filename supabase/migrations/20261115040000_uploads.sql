-- zone2.day: one-time upload links (MCP create_upload_link). A chat client cannot pass a binary
-- file to a tool, so the coach hands the athlete a link, the athlete picks the file in the browser,
-- and import_activity_file({uploadId}) turns it into an activity. The secret is the URL token.

create table zone2.uploads (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references zone2.users(id) on delete cascade,
  token_hash text not null unique,           -- sha256 of the URL token
  kind text not null check (kind in ('fit')),
  expires_at timestamptz not null,
  storage_key text,                          -- set once the file is uploaded
  bytes int,
  filename text,
  uploaded_at timestamptz,
  activity_id uuid references zone2.activities(id) on delete set null,  -- set by import
  created_at timestamptz not null default now()
);
create index uploads_user_idx on zone2.uploads (user_id, created_at desc);

do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke all on all tables in schema zone2 from %I', r);
    end if;
  end loop;
end $$;
