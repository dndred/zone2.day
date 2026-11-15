# zone2.day — single entry point for humans and agents. `just` lists recipes.
# Docs: docs/08-dev-harness.md

set shell := ["zsh", "-cu"]

staging_ref := "udlqrxzuzoygmulwptee"
prod_ref := "tyeizwhaiigkkvipdvlz"
deno_perms := "--allow-net --allow-env --allow-read"

default:
    @just --list --unsorted

# Check that required tools are installed and logged in
bootstrap:
    #!/usr/bin/env zsh
    set -u
    ok=1
    for c in deno supabase wrangler op just xcodegen docker gh; do
      if command -v $c >/dev/null; then printf "✓ %-9s %s\n" $c "$($c --version 2>&1 | head -1)"; else printf "✗ %-9s missing\n" $c; ok=0; fi
    done
    supabase projects list >/dev/null 2>&1 && echo "✓ supabase login" || { echo "✗ supabase login (run: supabase login)"; ok=0; }
    wrangler whoami >/dev/null 2>&1 && echo "✓ wrangler login" || { echo "✗ wrangler login (run: wrangler login)"; ok=0; }
    op vault list >/dev/null 2>&1 && echo "✓ 1password cli" || { echo "✗ 1password cli (enable CLI integration in the 1Password app)"; ok=0; }
    [[ $ok == 1 ]]

# Enable the repo's git hooks (.githooks/pre-commit: check, lint, fmt, MCP contract on the staged snapshot)
hooks:
    git config core.hooksPath .githooks
    @echo "hooks enabled: .githooks"

# Run the API locally on :8787 with hot reload
dev:
    cd backend && ZONE2_ENV=local deno task dev

# All automated tests that do not need a device
test: test-backend test-kit

# Backend + edge proxy tests (Deno); DB tests use a throwaway database in the test container
test-backend: test-db-up
    deno test {{deno_perms}} --allow-write=/tmp

# Accept MCP contract changes into schema/mcp-tools.json (review the diff!)
mcp-snapshot-update: test-db-up
    UPDATE_MCP_SNAPSHOT=1 deno test {{deno_perms}} --allow-write backend/tests/mcp_contract_test.ts

# Start the Postgres container used by tests (localhost:54329, image postgres:13)
test-db-up:
    #!/usr/bin/env zsh
    set -eu
    docker start zone2-test-pg >/dev/null 2>&1 || docker run -d --name zone2-test-pg -e POSTGRES_PASSWORD=postgres -p 54329:5432 postgres:13 >/dev/null
    for i in {1..40}; do pg_isready -q -h localhost -p 54329 && exit 0; sleep 0.25; done
    echo "test postgres did not start"; exit 1

# Swift package tests on macOS (fast, no simulator)
test-kit:
    cd ios/Packages && swift test

# Generate the Xcode project from ios/project.yml
ios-gen:
    cd ios && xcodegen generate --quiet

# Build the iOS app for the simulator (no signing)
ios-build: ios-gen
    cd ios && xcodebuild -project Zone2.xcodeproj -scheme Zone2 -destination 'generic/platform=iOS Simulator' -derivedDataPath ../build/DerivedData build CODE_SIGNING_ALLOWED=NO -quiet

# Run in the booted simulator (iOS 26+) on demo data: just ios-sim; lang=en for English
ios-sim lang="ru": ios-build
    #!/usr/bin/env zsh
    set -euo pipefail
    udid=$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)
    [[ -n $udid ]] || { echo "no booted simulator"; exit 1; }
    xcrun simctl install $udid build/DerivedData/Build/Products/Debug-iphonesimulator/Zone2.app
    xcrun simctl launch --terminate-running-process $udid day.zone2.app \
      -DemoFeed $PWD/fixtures/sync/demo-feed.json -AppleLanguages "({{lang}})"

# Build, sign (Personal Team), install and launch on the connected iPhone. Also renews the 7-day profile.
# just ios-device → zone2 (prod); just ios-device stg → zone2 stg (staging). Two copies side by side.
ios-device app="prod":
    #!/usr/bin/env zsh
    set -euo pipefail
    tmp=$(mktemp)
    xcrun devicectl list devices --json-output "$tmp" >/dev/null
    udid=$(python3 -c "import json,sys; d=json.load(open('$tmp'))['result']['devices']; p=[x['hardwareProperties']['udid'] for x in d if x['hardwareProperties'].get('reality')=='physical' and x['hardwareProperties'].get('platform')=='iOS']; print(p[0] if p else '')")
    rm -f "$tmp"
    [[ -n $udid ]] || { echo "No physical iPhone connected"; exit 1; }
    cd ios && xcodegen generate --quiet
    case "{{app}}" in
      prod) scheme=Zone2; bundle=day.zone2.app ;;
      stg) scheme=Zone2Stg; bundle=day.zone2.app.stg ;;
      *) echo "app: prod | stg"; exit 1 ;;
    esac
    xcodebuild -project Zone2.xcodeproj -scheme $scheme -configuration Debug -destination "id=$udid" -derivedDataPath ../build/DerivedData -allowProvisioningUpdates -allowProvisioningDeviceRegistration build -quiet
    xcrun devicectl device install app --device "$udid" ../build/DerivedData/Build/Products/Debug-iphoneos/$scheme.app >/dev/null
    xcrun devicectl device process launch --device "$udid" $bundle >/dev/null && echo "installed and launched $bundle on $udid"

# Pull a file from the app container on the iPhone, e.g. just ios-pull Documents/wakes.jsonl
ios-pull path dest="build/device" app="prod":
    #!/usr/bin/env zsh
    set -euo pipefail
    mkdir -p {{dest}}
    tmp=$(mktemp)
    xcrun devicectl list devices --json-output "$tmp" >/dev/null
    udid=$(python3 -c "import json; d=json.load(open('$tmp'))['result']['devices']; p=[x['hardwareProperties']['udid'] for x in d if x['hardwareProperties'].get('reality')=='physical']; print(p[0] if p else '')")
    rm -f "$tmp"
    xcrun devicectl device copy from --device "$udid" --domain-type appDataContainer --domain-identifier {{ if app == "stg" { "day.zone2.app.stg" } else { "day.zone2.app" } }} --source "{{path}}" --destination "{{dest}}/$(basename "{{path}}")" >/dev/null && echo "→ {{dest}}/$(basename "{{path}}")"

# Type check everything TypeScript
check:
    deno check backend/src backend/tests edge-proxy/src supabase/functions/api/index.ts

# Lint and verify formatting
lint:
    deno lint
    deno fmt --check

# Format code
fmt:
    deno fmt

# Full local gate: check + lint + tests
ci: check lint test ios-build

# Deploy the Supabase function manually (CI does staging on push to main; prod needs ZONE2_ALLOW_PROD=1)
deploy-api target="staging": (_guard target)
    #!/usr/bin/env zsh
    # Normally CI deploys staging on push to main (.github/workflows/ci.yml); this is the manual path.
    set -euo pipefail
    ref={{ if target == "prod" { prod_ref } else { staging_ref } }}
    version=$(git rev-parse --short HEAD)$([[ -z "$(git status --porcelain -- backend supabase)" ]] || echo -dirty)
    # The version is baked into the bundle, so /health always reports the code that is actually live.
    trap 'git checkout -- supabase/functions/api/build.ts' EXIT
    echo "export const BUILD_VERSION = \"$version\";" > supabase/functions/api/build.ts
    # Local (Docker) bundling: server-side bundling (--use-api) times out on our bundle size.
    supabase functions deploy api --yes --remote=$ref 2>&1 | grep -vE "^(Uploading|Warning)" | tail -3
    echo "deployed $version"

# Set runtime secrets of the function (rarely changes; CI does not touch them)
deploy-secrets target="staging": (_guard target)
    supabase secrets set --yes --remote={{ if target == "prod" { prod_ref } else { staging_ref } }} \
      ZONE2_ENV={{target}} \
      ZONE2_PUBLIC_BASE_URL={{ if target == "prod" { "https://api.zone2.day" } else { "https://api-staging.zone2.day" } }} \
      ZONE2_RP_ID=zone2.day \
      ZONE2_SECRET_KEY="$(tools/secret.sh {{target}} secret_key)" \
      ZONE2_JOB_SECRET="$(tools/secret.sh {{target}} job_secret)"

# Put CI deploy secrets into GitHub (SUPABASE_ACCESS_TOKEN must be in .env.staging.local first)
gh-secrets:
    #!/usr/bin/env zsh
    set -euo pipefail
    token=$(grep '^ZONE2_SUPABASE_ACCESS_TOKEN=' .env.staging.local | cut -d= -f2-)
    [[ -n $token ]] || { echo "add ZONE2_SUPABASE_ACCESS_TOKEN to .env.staging.local"; exit 1; }
    print -rn -- "$token" | gh secret set SUPABASE_ACCESS_TOKEN
    tools/secret.sh staging db_password | gh secret set STAGING_DB_PASSWORD
    tools/secret.sh staging job_secret | gh secret set STAGING_JOB_SECRET
    gh secret list

# Create the 1Password item with app secrets for a target (once)
app-secrets target="staging": (_guard target)
    #!/usr/bin/env zsh
    set -eu
    if op item get "zone2-{{target}} app secrets" --vault "dev tools" >/dev/null 2>&1; then echo "exists"; exit 0; fi
    op item create --vault "dev tools" --category "API Credential" --title "zone2-{{target}} app secrets" --tags zone2.day \
      "secret_key[password]=$(openssl rand -base64 48 | tr -d '\n/+=' | cut -c1-48)" >/dev/null
    echo "created 1Password item: zone2-{{target}} app secrets"

# Cache staging secrets locally (.env.staging.local, gitignored, 600) so deploys need no 1Password prompt
cache-secrets:
    #!/usr/bin/env zsh
    set -euo pipefail
    umask 077
    {
      echo "# zone2.day staging secrets cache — generated by 'just cache-secrets'. Never commit. Source of truth: 1Password."
      echo "ZONE2_STAGING_DB_PASSWORD=$(op read 'op://dev tools/zone2-staging Supabase DB/password')"
      echo "ZONE2_STAGING_SECRET_KEY=$(op read 'op://dev tools/zone2-staging app secrets/secret_key')"
    } > .env.staging.local
    chmod 600 .env.staging.local
    echo "cached → .env.staging.local"

# Run a maintenance job until done, e.g. just job data-migrations (CI runs it only on a manual dispatch)
job name target="staging": (_guard target)
    #!/usr/bin/env zsh
    set -euo pipefail
    base={{ if target == "prod" { "https://api.zone2.day" } else { "https://api-staging.zone2.day" } }}
    secret=$(tools/secret.sh {{target}} job_secret)
    while true; do
      out=$(curl -fsS --max-time 120 -X POST "$base/jobs/{{name}}" -H "x-zone2-job-secret: $secret")
      echo "$out"
      [[ $(echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('remaining',0) > 0 and d.get('processed',0) > 0)") == True ]] || break
    done

# Apply supabase/migrations to a remote database
db-push target="staging": (_guard target)
    supabase db push --yes --remote={{ if target == "prod" { prod_ref } else { staging_ref } }} \
      -p "$(tools/secret.sh {{target}} db_password)"

# Create the staging "smoke" user + long-lived MCP token (cached in .env.staging.local). Not your data.
smoke-token:
    #!/usr/bin/env zsh
    set -euo pipefail
    if grep -q '^ZONE2_STAGING_SMOKE_TOKEN=' .env.staging.local 2>/dev/null; then echo "exists"; exit 0; fi
    token="z2a_$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')"
    hash=$(printf %s "$token" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')
    uid=00000000-0000-4000-8000-00000000500e
    supabase db query --yes --remote={{staging_ref}} "insert into zone2.users (id, display_name) values ('$uid', 'smoke') on conflict do nothing; insert into zone2.oauth_clients (client_id, client_name, redirect_uris) values ('smoke-cli', 'smoke-cli', '{}') on conflict do nothing; insert into zone2.oauth_tokens (token_hash, kind, client_id, user_id, scopes, resource, family_id, expires_at) values ('$hash', 'access', 'smoke-cli', '$uid', '{mcp}', null, gen_random_uuid(), now() + interval '365 days')" >/dev/null
    umask 077; echo "ZONE2_STAGING_SMOKE_TOKEN=$token" >> .env.staging.local
    echo "smoke token created"

# Call an MCP tool on staging as the smoke user, e.g. just mcp get_context
mcp tool args="{}":
    #!/usr/bin/env zsh
    set -euo pipefail
    token=$(grep '^ZONE2_STAGING_SMOKE_TOKEN=' .env.staging.local | cut -d= -f2-)
    body=$(python3 -c "import json,sys; print(json.dumps({'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':sys.argv[1],'arguments':json.loads(sys.argv[2])}}))" "{{tool}}" '{{args}}')
    curl -sS --max-time 60 https://api-staging.zone2.day/mcp -H "authorization: Bearer $token" -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' -H 'mcp-protocol-version: 2025-06-18' -d "$body" \
      | python3 -c "import json,sys; r=json.load(sys.stdin); res=r.get('result') or {}; t=(res.get('content') or [{}])[0].get('text'); print(json.dumps(json.loads(t), ensure_ascii=False, indent=2) if t else json.dumps(r, ensure_ascii=False, indent=2)); sys.exit(1 if res.get('isError') or r.get('error') else 0)"

# Read-only SQL against a remote database, e.g. just db-ro "select count(*) from zone2.users"
db-ro sql target="staging":
    supabase db query --read-only --remote={{ if target == "prod" { prod_ref } else { staging_ref } }} "{{sql}}" -o table

# Create a sign-up invite; the code goes to 1Password ("zone2-<target> invite <date>"), never to stdout
invite target="staging" note="cli": (_guard target)
    #!/usr/bin/env zsh
    set -euo pipefail
    code="$(openssl rand -hex 3 | tr a-f A-F)-$(openssl rand -hex 3 | tr a-f A-F)"
    hash=$(printf %s "$code" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')
    supabase db query --yes --remote={{ if target == "prod" { prod_ref } else { staging_ref } }} \
      "insert into zone2.invites (code_hash, note, expires_at) values ('$hash', '{{note}}', now() + interval '7 days')" >/dev/null
    title="zone2-{{target}} invite $(date +%Y-%m-%d_%H%M)"
    op item create --vault "dev tools" --category Password --title "$title" --tags zone2.day "password=$code" >/dev/null
    echo "invite created (valid 7 days) → 1Password: $title"

# Deploy the Cloudflare edge proxy (target=staging|prod)
deploy-proxy target="staging": (_guard target)
    cd edge-proxy && wrangler deploy --env {{target}}

# Deploy API + proxy, then smoke test
deploy target="staging": (deploy-api target) (deploy-proxy target) (smoke target)

# Smoke test a deployed environment through the public URL (waits for the new version to roll out)
smoke target="staging":
    #!/usr/bin/env zsh
    set -eu
    want=$(git rev-parse --short HEAD)
    base={{ if target == "prod" { "https://api.zone2.day" } else if target == "local" { "http://localhost:8787" } else { "https://api-staging.zone2.day" } }}
    for i in {1..12}; do
      body=$(curl -fsS --max-time 20 "$base/health")
      [[ "{{target}}" == local || "$body" == *"$want"* ]] && break
      sleep 5
    done
    echo "$body"
    echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['ok'] and d['env']=='{{target}}', d; print('✓ health ok:', d['env'], d['version'])"
    if [[ "{{target}}" != local && "$body" != *"$want"* ]]; then echo "✗ live version is not HEAD ($want) — deploy did not go out"; exit 1; fi

# Edge Function logs (Supabase Management API, read-only), newest last.
#   just logs                       — staging, last 30 min
#   just logs staging 2h mcp        — window: 30m / 2h / 1d; filter: substring of the line
#   just logs prod 1h error         — prod is read-only here, no guard
# Sources: our JSON lines (function_logs); add src=edge for Supabase's request log.
# The logs endpoint allows 10 requests/min per account.
logs target="staging" since="30m" grep="" src="fn" limit="300":
    #!/usr/bin/env zsh
    set -euo pipefail
    export ZONE2_SUPABASE_ACCESS_TOKEN=${ZONE2_SUPABASE_ACCESS_TOKEN:-$(grep '^ZONE2_SUPABASE_ACCESS_TOKEN=' .env.staging.local 2>/dev/null | cut -d= -f2- || true)}
    [[ -n $ZONE2_SUPABASE_ACCESS_TOKEN ]] || { echo "no ZONE2_SUPABASE_ACCESS_TOKEN (env or .env.staging.local)"; exit 1; }
    python3 -I scripts/logs.py {{ if target == "prod" { prod_ref } else { staging_ref } }} {{quote(since)}} {{quote(grep)}} {{quote(src)}} {{quote(limit)}}

# Back up an environment to ~/Backups/zone2/<target>: zone2 schema + data (gzip, last 12 kept) and
# a mirror of the Storage bucket (workout originals). Read-only on the server. `min_days` > 0 skips
# when the last backup is younger (the daily launchd job uses 7 → weekly, catches up after sleep).
backup target="prod" min_days="0":
    #!/usr/bin/env zsh
    set -euo pipefail
    ref={{ if target == "prod" { prod_ref } else { staging_ref } }}
    root=$HOME/Backups/zone2/{{target}}
    mkdir -p $root/db $root/files
    last=$(ls -1t $root/db/*.sql.gz 2>/dev/null | head -1 || true)
    if [[ -n $last && {{min_days}} -gt 0 ]]; then
      age=$(( ($(date +%s) - $(stat -f %m "$last")) / 86400 ))
      if (( age < {{min_days}} )); then echo "last backup $age d ago ($last) — skip"; exit 0; fi
    fi
    pw=$(tools/secret.sh {{target}} db_password)
    stamp=$(date +%Y-%m-%d_%H%M)
    tmp=$(mktemp -d); trap 'rm -rf $tmp' EXIT
    supabase db dump --remote=$ref -p "$pw" -s zone2 -f $tmp/schema.sql >/dev/null
    supabase db dump --remote=$ref -p "$pw" -s zone2 --data-only --use-copy -f $tmp/data.sql >/dev/null
    cat $tmp/schema.sql $tmp/data.sql | gzip -9 > $root/db/$stamp.sql.gz.part && mv $root/db/$stamp.sql.gz.part $root/db/$stamp.sql.gz
    export ZONE2_SERVICE_KEY=$(supabase projects api-keys --remote=$ref -o json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(next(k['api_key'] for k in d if k.get('name')=='service_role'))")
    python3 -I scripts/backup_storage.py $ref activity-files $root/files
    for old in $(ls -1t $root/db/*.sql.gz | tail -n +13); do rm -f -- "$old"; done
    echo "backup → $root/db/$stamp.sql.gz ($(du -h $root/db/$stamp.sql.gz | cut -f1)), files: $(du -sh $root/files | cut -f1)"

# Install the daily launchd job that runs `just backup prod 7` (log: ~/Backups/zone2/backup.log;
# a notification on failure, e.g. when 1Password was locked — it retries the next day)
backup-install:
    #!/usr/bin/env zsh
    set -euo pipefail
    plist=$HOME/Library/LaunchAgents/day.zone2.backup.plist
    mkdir -p $HOME/Backups/zone2 $HOME/Library/LaunchAgents
    cmd="cd '{{justfile_directory()}}' && just backup prod 7 >> \$HOME/Backups/zone2/backup.log 2>&1 || osascript -e 'display notification \"Backup failed — see ~/Backups/zone2/backup.log\" with title \"zone2.day\"'"
    cat > $plist <<PLIST
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>Label</key><string>day.zone2.backup</string>
      <key>ProgramArguments</key><array><string>/bin/zsh</string><string>-lc</string><string>$cmd</string></array>
      <key>StartCalendarInterval</key><dict><key>Hour</key><integer>12</integer><key>Minute</key><integer>0</integer></dict>
    </dict></plist>
    PLIST
    launchctl bootout gui/$UID $plist 2>/dev/null || true
    launchctl bootstrap gui/$UID $plist
    echo "installed $plist (daily 12:00, backs up when the last one is ≥ 7 days old)"

# Live logs of the edge proxy
proxy-logs target="staging":
    cd edge-proxy && wrangler tail --env {{target}} --format pretty

# Print a secret from 1Password (vault "dev tools"), e.g. just secret "zone2-prod Supabase DB" password
secret item field="password":
    @op read "op://dev tools/{{item}}/{{field}}"

[private]
_guard target:
    #!/usr/bin/env zsh
    case "{{target}}" in
      staging) ;;
      prod) [[ "${ZONE2_ALLOW_PROD:-}" == "1" ]] || { echo "Refusing to touch prod: set ZONE2_ALLOW_PROD=1"; exit 1; } ;;
      *) echo "Unknown target {{target}} (staging|prod)"; exit 1 ;;
    esac
