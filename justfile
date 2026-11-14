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

# Run the API locally on :8787 with hot reload
dev:
    cd backend && ZONE2_ENV=local deno task dev

# All automated tests that do not need a device
test: test-backend test-kit

# Backend + edge proxy tests (Deno)
test-backend:
    deno test {{deno_perms}}

# Swift package tests on macOS (fast, no simulator)
test-kit:
    cd ios/Packages && swift test

# Generate the Xcode project from ios/project.yml
ios-gen:
    cd ios && xcodegen generate --quiet

# Build the iOS app for the simulator (no signing)
ios-build: ios-gen
    cd ios && xcodebuild -project Zone2.xcodeproj -scheme Zone2 -destination 'generic/platform=iOS Simulator' -derivedDataPath ../build/DerivedData build CODE_SIGNING_ALLOWED=NO -quiet

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

# Deploy the Supabase function (target=staging|prod; prod needs ZONE2_ALLOW_PROD=1)
deploy-api target="staging": (_guard target)
    supabase secrets set --yes --remote={{ if target == "prod" { prod_ref } else { staging_ref } }} \
      ZONE2_ENV={{target}} \
      ZONE2_VERSION=$(git rev-parse --short HEAD)$([[ -z "$(git status --porcelain -- backend supabase)" ]] || echo -dirty) \
      ZONE2_PUBLIC_BASE_URL={{ if target == "prod" { "https://api.zone2.day" } else { "https://api-staging.zone2.day" } }}
    supabase functions deploy api --yes --remote={{ if target == "prod" { prod_ref } else { staging_ref } }} --use-api

# Deploy the Cloudflare edge proxy (target=staging|prod)
deploy-proxy target="staging": (_guard target)
    cd edge-proxy && wrangler deploy --env {{target}}

# Deploy API + proxy, then smoke test
deploy target="staging": (deploy-api target) (deploy-proxy target) (smoke target)

# Smoke test a deployed environment through the public URL
smoke target="staging":
    #!/usr/bin/env zsh
    set -eu
    base={{ if target == "prod" { "https://api.zone2.day" } else if target == "local" { "http://localhost:8787" } else { "https://api-staging.zone2.day" } }}
    body=$(curl -fsS --max-time 20 "$base/health")
    echo "$body"
    echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['ok'] and d['env']=='{{target}}', d; print('✓ health ok:', d['env'], d['version'])"

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
