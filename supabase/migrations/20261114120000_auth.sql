-- zone2.day: accounts, passkeys and OAuth 2.1 (docs/02-architecture.md §6, docs/03-data-model.md §2.1).
-- All app tables live in schema "zone2", which is NOT exposed through Supabase Data API.

create schema if not exists zone2;

create table zone2.users (
  id uuid primary key default gen_random_uuid(),
  display_name text not null,
  created_at timestamptz not null default now()
);

create table zone2.invites (
  code_hash text primary key,              -- sha256(base64url) of the normalized code
  note text,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_by uuid references zone2.users(id) on delete set null,
  used_at timestamptz
);

create table zone2.passkeys (
  id text primary key,                     -- WebAuthn credential id (base64url)
  user_id uuid not null references zone2.users(id) on delete cascade,
  public_key bytea not null,
  counter bigint not null default 0,
  transports text[] not null default '{}',
  device_type text,
  backed_up boolean,
  created_at timestamptz not null default now(),
  last_used_at timestamptz
);
create index passkeys_user_idx on zone2.passkeys(user_id);

create table zone2.webauthn_challenges (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('register', 'login')),
  challenge text not null,
  user_id uuid,                            -- pre-generated id of the user being registered
  invite_code_hash text,
  display_name text,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);

create table zone2.oauth_clients (
  client_id text primary key,
  client_secret_hash text,                 -- null for public clients
  client_name text,
  redirect_uris text[] not null,
  token_endpoint_auth_method text not null default 'none'
    check (token_endpoint_auth_method in ('none', 'client_secret_post', 'client_secret_basic')),
  kind text not null default 'dcr' check (kind in ('dcr', 'first_party')),
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now()
);

create table zone2.oauth_codes (
  code_hash text primary key,
  client_id text not null references zone2.oauth_clients(client_id) on delete cascade,
  user_id uuid not null references zone2.users(id) on delete cascade,
  redirect_uri text not null,
  code_challenge text not null,
  scopes text[] not null,
  resource text,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz
);

create table zone2.oauth_tokens (
  token_hash text primary key,
  kind text not null check (kind in ('access', 'refresh')),
  client_id text not null references zone2.oauth_clients(client_id) on delete cascade,
  user_id uuid not null references zone2.users(id) on delete cascade,
  scopes text[] not null,
  resource text,
  family_id uuid not null,                 -- refresh-token rotation family (reuse ⇒ revoke family)
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz
);
create index oauth_tokens_user_idx on zone2.oauth_tokens(user_id);
create index oauth_tokens_family_idx on zone2.oauth_tokens(family_id);

-- Defense in depth: Supabase API roles must never reach this schema.
do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke all on schema zone2 from %I', r);
      execute format('revoke all on all tables in schema zone2 from %I', r);
      execute format('alter default privileges in schema zone2 revoke all on tables from %I', r);
    end if;
  end loop;
end $$;
