# Netflixx
# One-time setup: check the drive, create the folder layout, set ownership.
# Run from anywhere: ~/netflixx/scripts/setup.sh
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || { echo "No .env yet. Run: cp .env.example .env, then fill it in."; exit 1; }
set -a; . ./.env; set +a
: "${DATA_ROOT:?DATA_ROOT is empty in .env}"
PUID=${PUID:-1000}
PGID=${PGID:-1000}

# The data folder must be its own mounted drive, not a folder on the 120 GB
# system SSD that would quietly fill it up.
if ! mountpoint -q "$DATA_ROOT"; then
  echo "$DATA_ROOT is not a mounted drive. Mount the media drive there first (see README, step 1)."
  exit 1
fi

echo "Creating the folders under $DATA_ROOT"
sudo mkdir -p "$DATA_ROOT"/torrents/{movies,tv} "$DATA_ROOT"/media/{movies,tv}
sudo chown -R "$PUID:$PGID" "$DATA_ROOT"/torrents "$DATA_ROOT"/media
# Owner and group can read and write; everyone else can only read and open folders.
sudo chmod -R u=rwX,g=rwX,o=rX "$DATA_ROOT"/torrents "$DATA_ROOT"/media

echo "Creating the config folders"
mkdir -p config/{jellyfin,sonarr,radarr,prowlarr,bazarr,gluetun,qbittorrent,seerr}
# Seerr's image always runs as user 1000, whatever PUID says.
sudo chown -R 1000:1000 config/seerr

echo
echo "Done. Start the stack with: docker compose up -d"
echo "Then check it with:         scripts/check.sh"
