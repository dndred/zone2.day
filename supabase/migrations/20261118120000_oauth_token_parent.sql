-- Refresh rotation lineage: every issued token remembers the refresh token it was issued for.
-- Lets the token endpoint tell a lost response (the app retries the previous refresh token and
-- never used what it was given) from reuse of a stolen token (docs/02-architecture.md §6).
alter table zone2.oauth_tokens add column parent_hash text;
create index oauth_tokens_parent_idx on zone2.oauth_tokens(parent_hash) where parent_hash is not null;
