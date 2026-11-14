#!/usr/bin/env zsh
# Prints a deployment secret. Usage: tools/secret.sh <staging|prod> <db_password|secret_key>
# staging: read from the local cache .env.staging.local (gitignored, chmod 600) if present,
#          otherwise from 1Password. `just cache-secrets` fills the cache.
# prod:    always 1Password (never cached on disk).
set -euo pipefail
target=$1
name=$2
root=${0:A:h:h}

case $name in
  db_password) ref="op://dev tools/zone2-$target Supabase DB/password" ;;
  secret_key) ref="op://dev tools/zone2-$target app secrets/secret_key" ;;
  job_secret) ref="op://dev tools/zone2-$target app secrets/job_secret" ;;
  *) print -u2 "unknown secret: $name"; exit 1 ;;
esac

if [[ $target == staging && -f $root/.env.staging.local ]]; then
  var="ZONE2_STAGING_${name:u}"
  val=$(grep -E "^${var}=" "$root/.env.staging.local" | head -1 | cut -d= -f2-)
  if [[ -n $val ]]; then
    print -rn -- "$val"
    exit 0
  fi
fi

op read "$ref"
