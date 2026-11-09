#!/bin/bash
# Sets up the Cloudflare side of Lifelog (idempotent — safe to re-run):
#   R2 bucket (media) · D1 database (timeline) · Worker (API + web viewer) · API token secret
# and writes cloudUrl / cloudToken into ~/Lifelog/config.json for the laptop uploader.
set -euo pipefail
cd "$(dirname "$0")"
export WRANGLER_SEND_METRICS=false
DATA="${LIFELOG_DIR:-$HOME/Lifelog}"
CONFIG="$DATA/config.json"
mkdir -p "$DATA"; [ -f "$CONFIG" ] || echo '{}' > "$CONFIG"
cfg() { python3 -c "import json,sys; print(json.load(open('$CONFIG')).get('$1') or '$2')"; }
BUCKET=$(cfg r2Bucket lifelog-media)
DBNAME=lifelog

command -v python3 >/dev/null || { echo "python3 not found (install Xcode command line tools: xcode-select --install)" >&2; exit 1; }
command -v wrangler >/dev/null || { echo "wrangler not found — install it with: npm i -g wrangler  (needs Node.js: brew install node)" >&2; exit 1; }
wrangler whoami >/dev/null 2>&1 || { echo "Not logged in to Cloudflare — run: wrangler login" >&2; exit 1; }

# wrangler.toml is per-account (it holds your D1 database id), so it's gitignored and made from the template
[ -f wrangler.toml ] || /bin/cp wrangler.example.toml wrangler.toml

echo "→ R2 bucket $BUCKET"
wrangler r2 bucket list 2>/dev/null | grep -qE "^name: +$BUCKET\$" || wrangler r2 bucket create "$BUCKET"

echo "→ D1 database $DBNAME"
dbid() { wrangler d1 list --json 2>/dev/null | python3 -c "import json,sys; print(next((d['uuid'] for d in json.load(sys.stdin) if d['name']=='$DBNAME'), ''))"; }
DBID=$(dbid)
[ -n "$DBID" ] || { wrangler d1 create "$DBNAME" >/dev/null; DBID=$(dbid); }
sed -i '' -E "s/^database_id = .*/database_id = \"$DBID\"/; s/^bucket_name = .*/bucket_name = \"$BUCKET\"/" wrangler.toml
wrangler d1 execute "$DBNAME" --remote --file schema.sql -y >/dev/null
# migrations for databases created by older versions (errors = already applied)
wrangler d1 execute "$DBNAME" --remote -y --command "ALTER TABLE transcripts ADD COLUMN speaker TEXT" >/dev/null 2>&1 || true

echo "→ Worker"
/bin/cp -f ../pipeline/report.html public/index.html
TOKEN=$(cfg cloudToken "")
[ -n "$TOKEN" ] || TOKEN=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
OUT=$(wrangler deploy 2>&1) || { echo "$OUT"; exit 1; }
URL=$(echo "$OUT" | grep -oE 'https://[a-zA-Z0-9.-]+\.workers\.dev' | head -1)
# set the API token and make sure the live Worker actually accepts it (secret propagation can lag a deploy)
for _ in 1 2 3 4 5; do
  printf '%s' "$TOKEN" | wrangler secret put API_TOKEN >/dev/null
  [ -z "$URL" ] && break
  sleep 5
  code=$(curl -s -o /dev/null -w "%{http_code}" "$URL/api/ping" -H "authorization: Bearer $TOKEN")
  [ "$code" = 200 ] && break
  echo "  token not active yet (HTTP $code), retrying…"
done
# a second, narrower token for the cloud analysis agent (reads everything, writes only its analysis results)
ANALYST=$(cfg analystToken "")
[ -n "$ANALYST" ] || ANALYST=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
printf '%s' "$ANALYST" | wrangler secret put ANALYST_TOKEN >/dev/null
# and one for the iPhone app (baked into it at build time): upload-only
PHONE=$(cfg phoneToken "")
[ -n "$PHONE" ] || PHONE=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
printf '%s' "$PHONE" | wrangler secret put PHONE_TOKEN >/dev/null
[ -n "$URL" ] || { echo "$OUT" | tail -15; echo "Deployed, but couldn't find the workers.dev URL above — set cloudUrl in $CONFIG yourself."; }

python3 - "$CONFIG" "$URL" "$TOKEN" "$ANALYST" "$PHONE" <<'PY'
import json, sys
path, url, token, analyst, phone = sys.argv[1:]
c = json.load(open(path))
if url: c["cloudUrl"] = url
c["cloudToken"] = token
c["analystToken"] = analyst
c["phoneToken"] = phone
json.dump(c, open(path, "w"), indent=2, sort_keys=True)
PY
chmod 600 "$CONFIG"

cat <<MSG

✓ Cloud ready: $URL
  Open on your phone (once, it remembers the token):  $URL/?token=$TOKEN
  The token is in $CONFIG (cloudToken) — anyone with it can see everything, so keep it private.
MSG
