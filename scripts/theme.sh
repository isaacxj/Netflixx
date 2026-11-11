#!/usr/bin/env bash
# Installs the Netflixx look into Jellyfin, or takes it out again.
#   scripts/theme.sh          install or update theme/netflixx.css
#   scripts/theme.sh remove   back to Jellyfin's own look
#
# Needs an API key: Jellyfin Dashboard > API Keys > +, then JELLYFIN_API_KEY=... in .env.
# Jellyfin keeps the CSS in its settings, so this only runs again when the theme changes.
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] && { set -a; . ./.env; set +a; }
URL=${JELLYFIN_URL:-http://127.0.0.1:8096}
KEY=${JELLYFIN_API_KEY:-}
CSS_FILE=theme/netflixx.css
mode=${1:-apply}

if [ -z "$KEY" ]; then
  echo "No JELLYFIN_API_KEY in .env. Make one in Jellyfin: Dashboard > API Keys > +"
  exit 1
fi
case "$mode" in apply|remove) ;; *) echo "Usage: scripts/theme.sh [remove]"; exit 1 ;; esac

auth="Authorization: MediaBrowser Token=\"$KEY\""
current=$(curl -fsS -H "$auth" "$URL/System/Configuration/branding") || {
  echo "Jellyfin didn't accept the request at $URL. Is it running, and is the API key right?"
  exit 1
}

# Keep a copy of whatever custom CSS was there before, unless it's already ours.
mkdir -p config
CURRENT="$current" python3 -c '
import json, os, sys
css = json.loads(os.environ["CURRENT"]).get("CustomCss") or ""
if css.strip() and "Netflixx" not in css:
    open("config/jellyfin-custom-css.backup", "w").write(css)
    print("Saved your previous custom CSS to config/jellyfin-custom-css.backup")
'

body=$(CURRENT="$current" MODE="$mode" CSS_FILE="$CSS_FILE" python3 -c '
import json, os
cur = json.loads(os.environ["CURRENT"])
css = open(os.environ["CSS_FILE"]).read() if os.environ["MODE"] == "apply" else ""
print(json.dumps({
    "LoginDisclaimer": cur.get("LoginDisclaimer"),
    "CustomCss": css,
    "SplashscreenEnabled": bool(cur.get("SplashscreenEnabled")),
}))')

curl -fsS -o /dev/null -X POST -H "$auth" -H "Content-Type: application/json" \
  --data "$body" "$URL/System/Configuration/Branding" || {
  echo "Jellyfin refused the change. The API key needs to belong to an admin."
  exit 1
}

if [ "$mode" = apply ]; then
  echo "Netflixx theme installed. Reload Jellyfin in the browser or app to see it."
else
  echo "Theme removed. Reload Jellyfin to see its own look again."
fi
