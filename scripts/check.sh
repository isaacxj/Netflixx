# Netflixx
# Checks the things that are easy to get wrong and hard to notice:
# the VPN really hides the home address, hardlinks work, and Quick Sync is visible.
# Run from anywhere: ~/netflixx/scripts/check.sh
set -uo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] && { set -a; . ./.env; set +a; }
DATA_ROOT=${DATA_ROOT:-/srv/data}
pass() { printf '  \033[32mok\033[0m    %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; failed=1; }
failed=0

echo "Containers"
for c in jellyfin seerr sonarr radarr prowlarr bazarr gluetun qbittorrent; do
  state=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)
  [ "$state" = running ] && pass "$c" || fail "$c is $state"
done

echo "VPN"
home_ip=$(curl -fsS --max-time 10 https://ipinfo.io/ip 2>/dev/null || true)
vpn_ip=$(docker exec qbittorrent curl -fsS --max-time 10 https://ipinfo.io/ip 2>/dev/null || true)
if [ -z "$vpn_ip" ]; then
  fail "qBittorrent can't reach the internet (is gluetun connected? docker logs gluetun)"
elif [ "$vpn_ip" = "$home_ip" ]; then
  fail "qBittorrent shows your home address ($home_ip). Stop it: docker stop qbittorrent"
else
  pass "qBittorrent goes out as $vpn_ip, home is ${home_ip:-unknown}"
fi

echo "Drive"
if mountpoint -q "$DATA_ROOT"; then
  pass "$DATA_ROOT is a mounted drive, $(df -h --output=avail "$DATA_ROOT" | tail -1 | tr -d ' ') free"
else
  fail "$DATA_ROOT is not a mounted drive"
fi
probe="$DATA_ROOT/torrents/.hardlink-check"
if touch "$probe" 2>/dev/null && ln "$probe" "$DATA_ROOT/media/.hardlink-check" 2>/dev/null; then
  pass "hardlinks work between torrents/ and media/"
  rm -f "$DATA_ROOT/media/.hardlink-check"
else
  fail "can't hardlink between torrents/ and media/ (same drive? run scripts/setup.sh)"
fi
rm -f "$probe"

echo "Quick Sync"
intel=""
for node in /sys/class/drm/renderD*; do
  [ "$(cat "$node/device/vendor" 2>/dev/null)" = 0x8086 ] && intel="/dev/dri/$(basename "$node")"
done
if [ -n "$intel" ] && docker exec jellyfin test -e "$intel" 2>/dev/null; then
  pass "Intel GPU is $intel and Jellyfin can see it. Use it as the QSV device."
else
  fail "Jellyfin can't see the Intel GPU (${intel:-not found on the host})"
fi

echo
[ "$failed" = 0 ] && echo "All good." || echo "Something needs fixing; see FAIL above."
exit "$failed"
