# Netflixx

The media stack on `stx-server`: Jellyfin for watching, Seerr for requesting, and the apps
that find, download, rename and subtitle what gets requested. One compose file, one
command to start or update it.

```
Seerr ──▶ Sonarr / Radarr ◀── Prowlarr (indexers)
               │
               ▼
     qBittorrent ── inside ──▶ Gluetun (VPN)
               │
               ▼  hardlink, no copy
   /srv/data/media ──▶ Jellyfin ──▶ iPhone, TV, laptop
                    └─▶ Bazarr (subtitles)
```

| App | Port | Does |
| --- | --- | --- |
| Seerr | 5055 | Request a movie or show. The one page you use day to day. |
| Sonarr | 8989 | TV: watches for episodes, grabs them, renames and files them. |
| Radarr | 7878 | Movies: the same job. |
| Prowlarr | 9696 | Holds the indexer list and pushes it to Sonarr and Radarr. |
| qBittorrent | 8081 | Downloads. Lives inside Gluetun's network, so no VPN means no traffic. |
| Bazarr | 6767 | Fetches subtitles for everything in the library. |
| Jellyfin | 8096 | Streams it all, with Intel Quick Sync transcoding. |

qBittorrent is on 8081 because openGym's web container already has 8080.

## Set up on stx-server

### 1. Mount the media drive

Use the internal 1 TB Seagate HDD; it's always connected, unlike the USB SSD. Find it:

```bash
lsblk -o NAME,SIZE,MODEL,FSTYPE,MOUNTPOINT
```

It's the 931G disk with model ST1000…, probably `sda`. **Formatting erases it**, so copy
off anything you want first. Make one partition and an ext4 filesystem on it:

```bash
sudo parted /dev/sda --script mklabel gpt mkpart media ext4 0% 100%
```

```bash
sudo mkfs.ext4 -L media /dev/sda1
```

Mount it at `/srv/data` on every boot. `nofail` lets the server still boot if the drive
ever dies:

```bash
sudo mkdir -p /srv/data
echo "UUID=$(sudo blkid -s UUID -o value /dev/sda1) /srv/data ext4 defaults,noatime,nofail 0 2" | sudo tee -a /etc/fstab
sudo systemctl daemon-reload && sudo mount -a && df -h /srv/data
```

`fstab` is the list of drives Linux mounts at boot. Using the UUID instead of `/dev/sda1`
means it still finds the right drive if plugging in the USB SSD shuffles the names.

### 2. Start the stack

```bash
git clone https://github.com/isaacxj/Netflixx.git ~/netflixx && cd ~/netflixx
cp .env.example .env && nano .env      # VPN key and address; check PUID/PGID with `id`
scripts/setup.sh
docker compose up -d
scripts/check.sh
```

`check.sh` confirms every container runs, qBittorrent's public address is the VPN's and
not home's, hardlinks work, and Jellyfin can see the Intel GPU. If the VPN check fails,
stop qBittorrent before doing anything else.

### 3. Connect the apps, in this order

Open each at `http://stx-server:<port>` from a device on the tailnet. Each one asks you to
create a login the first time; do it.

1. **qBittorrent** (8081): the first password is in `docker logs qbittorrent`. Change it.
   Under Downloads, default save path `/data/torrents`. Add categories `tv` →
   `/data/torrents/tv` and `movies` → `/data/torrents/movies`.
2. **Sonarr** (8989): Media Management → root folder `/data/media/tv`, and turn on
   "Use Hardlinks instead of Copy". Download Clients → qBittorrent, host `gluetun`,
   port `8081`, category `tv`.
3. **Radarr** (7878): the same, with `/data/media/movies` and category `movies`.
4. **Prowlarr** (9696): add your indexers. Settings → Apps → add Sonarr
   (`http://sonarr:8989`) and Radarr (`http://radarr:7878`) with their API keys
   (Settings → General in each).
5. **Bazarr** (6767): connect Sonarr and Radarr the same way, then pick languages and
   subtitle providers.
6. **Jellyfin** (8096): libraries Movies → `/data/media/movies`, Shows → `/data/media/tv`.
   Dashboard → Playback → Transcoding: **Intel QuickSync (QSV)**, device
   `/dev/dri/renderD129` (the one `check.sh` printed). Tick hardware decoding for
   H264, HEVC and VP9, and leave AV1 unticked (the 8th-gen chip can't decode it).
7. **Seerr** (5055): sign in with Jellyfin at `http://jellyfin:8096`, then add Sonarr and
   Radarr.

Containers find each other by name (`sonarr`, `jellyfin`), because compose puts them on one
private network. qBittorrent answers as `gluetun`, since it lives inside that container's
network.

### 4. Watch

Install Jellyfin on the iPhone and add the server as `http://stx-server:8096` (with
Tailscale on). Requests go through Seerr at `http://stx-server:5055`.

## Day to day

- **Update**: the Update button in stx-monitor's Control center, one app at a time, or
  everything at once with `docker compose pull && docker compose up -d`.
- **Back up** `~/netflixx/config/`. That's every app's settings and history. The media
  itself can be found again; the settings are an evening's work.
- **Logs**: stx-monitor's Logs page, or `docker compose logs -f sonarr`.

## Good to know

- Docker publishes ports around ufw, so these apps are reachable from the home network
  and the tailnet. The router forwards nothing, so not from the internet. Keep a login on
  every app anyway.
- Gluetun is labelled `stx.protected`, so the console can't stop it by mistake and leave
  qBittorrent cut off.
- Downloading something you don't have the rights to is copyright infringement in the US,
  VPN or not. Use the stack for media you own, public-domain films and Linux ISOs.
