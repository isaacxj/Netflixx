#!/usr/bin/env bash
# Starts AdGuard Home, runs its first-time setup, and adds the smart-TV blocklists.
# Safe to run again: it skips whatever is already done.
# Run from anywhere: ~/netflixx/scripts/adblock-setup.sh
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || { echo "No .env yet. Run: cp .env.example .env, then fill it in."; exit 1; }
set -a; . ./.env; set +a
: "${LAN_IP:?Set LAN_IP in .env to the home-network address of this server, like 192.168.1.134}"

API=http://127.0.0.1:3053/control
ADMIN_USER=${ADGUARD_USER:-admin}

# Ad, tracking and telemetry domains used by smart TVs, Fire TV in particular.
# AdGuard Home already starts with its own general list and AdAway's.
LISTS=(
  "Smart TV ads and tracking|https://raw.githubusercontent.com/Perflyst/PiHoleBlocklist/master/SmartTV.txt"
  "Fire TV ads and tracking|https://raw.githubusercontent.com/Perflyst/PiHoleBlocklist/master/AmazonFireTV.txt"
)

if ! ip -4 addr show | grep -q "inet ${LAN_IP}/"; then
  echo "This server doesn't have the address $LAN_IP. Check LAN_IP in .env (ip -4 addr shows the real one)."
  exit 1
fi

mkdir -p config/adguard/{work,conf}
echo "Starting AdGuard Home"
docker compose -f adblock/compose.yaml --env-file .env up -d

echo -n "Waiting for it to answer"
up=0
for _ in $(seq 1 30); do
  # Any HTTP answer means it's up (after setup, most pages ask for a password).
  code=$(curl -s -o /dev/null -w '%{http_code}' "$API/status" 2>/dev/null || true)
  [ "$code" != 000 ] && [ -n "$code" ] && { up=1; break; }
  echo -n "."; sleep 1
done
echo
[ "$up" = 1 ] || { echo "AdGuard Home didn't start. Check: docker logs adguard"; exit 1; }

# First run: the install API only exists until setup is done.
if curl -fsS -o /dev/null "$API/install/get_addresses" 2>/dev/null; then
  echo "First-time setup. Choose a password for the admin page (user: $ADMIN_USER, at least 8 characters)."
  while :; do
    read -rsp "Password: " pass1; echo
    read -rsp "Again:    " pass2; echo
    [ "$pass1" = "$pass2" ] || { echo "They don't match, try again."; continue; }
    [ "${#pass1}" -ge 8 ] || { echo "At least 8 characters, try again."; continue; }
    break
  done
  body=$(ADMIN_USER="$ADMIN_USER" PASS="$pass1" python3 -c '
import json, os
print(json.dumps({
    "web": {"ip": "0.0.0.0", "port": 3000},
    "dns": {"ip": "0.0.0.0", "port": 53},
    "username": os.environ["ADMIN_USER"],
    "password": os.environ["PASS"],
}))')
  curl -fsS -o /dev/null -X POST -H 'Content-Type: application/json' --data "$body" "$API/install/configure" \
    || { echo "Setup was refused. Check: docker logs adguard"; exit 1; }
  sleep 2
else
  echo "Already set up. Enter the admin password to add the blocklists."
  read -rsp "Password for $ADMIN_USER: " pass1; echo
fi

auth="$ADMIN_USER:$pass1"
curl -fsS -o /dev/null -u "$auth" "$API/status" || { echo "That password didn't work."; exit 1; }

existing=$(curl -fsS -u "$auth" "$API/filtering/status")
for entry in "${LISTS[@]}"; do
  name=${entry%%|*}; url=${entry#*|}
  if grep -qF "$url" <<<"$existing"; then
    echo "  have  $name"
  else
    body=$(NAME="$name" URL="$url" python3 -c 'import json,os; print(json.dumps({"name": os.environ["NAME"], "url": os.environ["URL"], "whitelist": False}))')
    curl -fsS -o /dev/null -u "$auth" -X POST -H 'Content-Type: application/json' --data "$body" "$API/filtering/add_url" \
      && echo "  added $name" || echo "  could not add $name (add it by hand under Filters > DNS blocklists)"
  fi
done

gateway=$(ip -4 route show default | awk '{print $3; exit}')
cat <<EOF

AdGuard Home is running.
  Admin page:  http://stx-server:3053  (user $ADMIN_USER)
  DNS server:  $LAN_IP

Your AT&T gateway can't hand this DNS server out to devices, so set it on the TV itself.
On the Fire TV: Settings > Network > your Wi-Fi > Forget, then join it again and choose Advanced:
  IP address:   a free address below .64, for example 192.168.1.50
  Gateway:      ${gateway:-192.168.1.254}
  Prefix:       24
  DNS 1:        $LAN_IP
  DNS 2:        leave blank, or $LAN_IP again (a public DNS here lets ads slip through)

Then watch Query Log on the admin page while you use the TV.
EOF
