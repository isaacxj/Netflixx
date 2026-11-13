#!/usr/bin/env bash
# Wires the apps together through their APIs: the README's "Connect the apps" steps,
# done for you. Safe to run again: anything already there is updated, not duplicated.
#
#   scripts/configure-apps.sh            everything, in order
#   scripts/configure-apps.sh sonarr     just some: qbittorrent sonarr radarr prowlarr
#                                        bazarr jellyfin seerr
#
# Passwords come from the environment, or it asks (nothing is written to disk):
#   QBIT_USER (default admin), QBIT_PASS        qBittorrent's Web UI login
#   JELLYFIN_USER, JELLYFIN_PASS                Jellyfin admin. On a fresh Jellyfin this
#                                               creates that account; Seerr signs in with it.
# API keys are read from each app's own config under config/.
#
# It never adds indexers to Prowlarr; those are your choice.
set -uo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] && { set -a; . ./.env; set +a; }

QBIT=http://127.0.0.1:8081
SONARR=http://127.0.0.1:8989
RADARR=http://127.0.0.1:7878
PROWLARR=http://127.0.0.1:9696
BAZARR=http://127.0.0.1:6767
JELLYFIN=http://127.0.0.1:8096
SEERR=http://127.0.0.1:5055

JAR=$(mktemp -d)
trap 'rm -rf "$JAR"' EXIT

ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; failed=1; }
failed=0

# req METHOD URL [curl args]: prints the body; on a non-2xx answer prints why and fails.
req() {
  local method=$1 url=$2 out code; shift 2
  out=$(curl -sS -X "$method" -w $'\n%{http_code}' "$@" "$url" 2>&1) || {
    echo "        $method $url: no answer (${out:0:200})" >&2; return 1; }
  code=${out##*$'\n'}; out=${out%$'\n'*}
  if [[ $code != 2* ]]; then
    echo "        $method ${url%%\?*} -> HTTP $code: ${out:0:300}" >&2; return 1
  fi
  printf '%s' "$out"
}
json() { req "$1" "$2" -H 'Content-Type: application/json' --data "$3" "${@:4}"; }

ask() { # ask VAR "prompt" [secret]
  [ -n "${!1:-}" ] && return
  [ -t 0 ] || { echo "Set $1 in the environment (no terminal to ask on)."; exit 1; }
  if [ "${3:-}" = secret ]; then read -rsp "$2: " "$1"; echo; else read -rp "$2: " "$1"; fi
}

arr_key() { sed -nE 's#.*<ApiKey>(.*)</ApiKey>.*#\1#p' "config/$1/config.xml"; }
SONARR_KEY=$(arr_key sonarr)
RADARR_KEY=$(arr_key radarr)
PROWLARR_KEY=$(arr_key prowlarr)
QBIT_USER=${QBIT_USER:-admin}

# ------------------------------------------------------------------ qBittorrent
qbittorrent() {
  echo "qBittorrent"
  ask QBIT_PASS "qBittorrent password for $QBIT_USER" secret
  local r=(-b "$JAR/qbit" -c "$JAR/qbit" -H "Referer: $QBIT")
  local login
  login=$(req POST "$QBIT/api/v2/auth/login" "${r[@]}" \
    --data-urlencode "username=$QBIT_USER" --data-urlencode "password=$QBIT_PASS") || { bad "login"; return 1; }
  # Older qBittorrent says "Ok."; 5.x answers 204 with no body. Either way it sets a session cookie.
  { [ "$login" = "Ok." ] || [ -z "$login" ]; } && grep -q QBT_SID "$JAR/qbit" \
    || { bad "login refused: wrong qBittorrent password?"; return 1; }

  local cats cat
  cats=$(req GET "$QBIT/api/v2/torrents/categories" "${r[@]}") || { bad "read categories"; return 1; }
  for cat in tv movies; do
    local verb=createCategory
    jq -e --arg c "$cat" 'has($c)' <<<"$cats" >/dev/null && verb=editCategory
    req POST "$QBIT/api/v2/torrents/$verb" "${r[@]}" \
      --data-urlencode "category=$cat" --data-urlencode "savePath=/data/torrents/$cat" >/dev/null \
      || { bad "category $cat"; continue; }
  done
  cats=$(req GET "$QBIT/api/v2/torrents/categories" "${r[@]}")
  for cat in tv movies; do
    [ "$(jq -r --arg c "$cat" '.[$c].savePath' <<<"$cats")" = "/data/torrents/$cat" ] \
      && ok "category $cat -> /data/torrents/$cat" || bad "category $cat not saved"
  done

  req POST "$QBIT/api/v2/app/setPreferences" "${r[@]}" \
    --data-urlencode 'json={"bypass_local_auth":true}' >/dev/null || { bad "set preferences"; return 1; }
  local prefs
  prefs=$(req GET "$QBIT/api/v2/app/preferences" "${r[@]}")
  [ "$(jq -r .bypass_local_auth <<<"$prefs")" = true ] \
    && ok "bypass authentication for clients on localhost" || bad "localhost bypass not saved"
  ok "default save path is $(jq -r .save_path <<<"$prefs")"

  # Gluetun only hands over the forwarded port when it changes, and that hand-off fails
  # until the localhost bypass is on. Push the current port now, the same way Gluetun
  # does: from inside its network, with no login, which also proves the bypass works.
  local port iface
  port=$(docker exec gluetun cat /tmp/gluetun/forwarded_port 2>/dev/null | tr -dc 0-9)
  if [ -z "$port" ]; then
    ok "no VPN forwarded port yet (Gluetun will hand it over when it gets one)"
  else
    iface=$(docker exec gluetun sh -c 'ls /sys/class/net' | grep -E '^(tun|wg)' | head -1)
    docker exec gluetun wget -qO- --post-data \
      "json={\"listen_port\":$port,\"current_network_interface\":\"$iface\",\"random_port\":false,\"upnp\":false}" \
      http://127.0.0.1:8081/api/v2/app/setPreferences >/dev/null 2>&1 \
      || { bad "Gluetun couldn't reach qBittorrent without a login (is the bypass on?)"; return 1; }
    prefs=$(req GET "$QBIT/api/v2/app/preferences" "${r[@]}")
    [ "$(jq -r '"\(.listen_port) \(.current_network_interface)"' <<<"$prefs")" = "$port $iface" ] \
      && ok "listening on the VPN's forwarded port $port, bound to $iface" \
      || bad "forwarded port $port not taken"
  fi
}

# ------------------------------------------------------------- Sonarr / Radarr
# arr NAME URL KEY ROOT CATEGORY_FIELD CATEGORY
arr() {
  local name=$1 url=$2 key=$3 root=$4 catfield=$5 cat=$6
  local h=(-H "X-Api-Key: $key")
  echo "$name"
  ask QBIT_PASS "qBittorrent password for $QBIT_USER (for $name's download client)" secret

  if req GET "$url/api/v3/rootfolder" "${h[@]}" | jq -e --arg p "$root" 'any(.[]; .path==$p)' >/dev/null; then
    ok "root folder $root (already there)"
  else
    json POST "$url/api/v3/rootfolder" "{\"path\":\"$root\"}" "${h[@]}" >/dev/null \
      && ok "root folder $root" || bad "root folder $root"
  fi

  local mm
  mm=$(req GET "$url/api/v3/config/mediamanagement" "${h[@]}") || { bad "read media management"; return 1; }
  mm=$(json PUT "$url/api/v3/config/mediamanagement/$(jq .id <<<"$mm")" \
    "$(jq '.copyUsingHardlinks=true' <<<"$mm")" "${h[@]}") || { bad "turn on hardlinks"; return 1; }
  [ "$(jq .copyUsingHardlinks <<<"$mm")" = true ] && ok "use hardlinks instead of copy" || bad "hardlinks not saved"

  local schema existing body
  schema=$(req GET "$url/api/v3/downloadclient/schema" "${h[@]}") || { bad "read client schema"; return 1; }
  existing=$(req GET "$url/api/v3/downloadclient" "${h[@]}" | jq '[.[] | select(.implementation=="QBittorrent")][0].id // empty')
  body=$(jq --arg u "$QBIT_USER" --arg p "$QBIT_PASS" --arg cf "$catfield" --arg c "$cat" --arg id "$existing" '
    [.[] | select(.implementation=="QBittorrent")][0]
    | .name="qBittorrent" | .enable=true | .priority=1
    | (if $id != "" then .id=($id|tonumber) else del(.id) end)
    | .fields |= map(
        if   .name=="host"     then .value="gluetun"
        elif .name=="port"     then .value=8081
        elif .name=="useSsl"   then .value=false
        elif .name=="username" then .value=$u
        elif .name=="password" then .value=$p
        elif .name==$cf        then .value=$c
        else . end)' <<<"$schema")
  json POST "$url/api/v3/downloadclient/test" "$body" "${h[@]}" >/dev/null \
    && ok "qBittorrent connection test passed (gluetun:8081)" \
    || { bad "qBittorrent connection test failed"; return 1; }
  if [ -n "$existing" ]; then
    json PUT "$url/api/v3/downloadclient/$existing" "$body" "${h[@]}" >/dev/null
  else
    json POST "$url/api/v3/downloadclient" "$body" "${h[@]}" >/dev/null
  fi && ok "download client qBittorrent, category $cat" || bad "save download client"
}
sonarr() { arr Sonarr "$SONARR" "$SONARR_KEY" /data/media/tv     tvCategory    tv; }
radarr() { arr Radarr "$RADARR" "$RADARR_KEY" /data/media/movies movieCategory movies; }

# ---------------------------------------------------------------------- Prowlarr
prowlarr() {
  echo "Prowlarr"
  local h=(-H "X-Api-Key: $PROWLARR_KEY") schema apps app body id
  schema=$(req GET "$PROWLARR/api/v1/applications/schema" "${h[@]}") || { bad "read app schema"; return 1; }
  apps=$(req GET "$PROWLARR/api/v1/applications" "${h[@]}") || { bad "read apps"; return 1; }
  for app in "Sonarr http://sonarr:8989 $SONARR_KEY" "Radarr http://radarr:7878 $RADARR_KEY"; do
    set -- $app
    id=$(jq --arg i "$1" '[.[] | select(.implementation==$i)][0].id // empty' <<<"$apps")
    body=$(jq --arg i "$1" --arg url "$2" --arg key "$3" --arg id "$id" '
      [.[] | select(.implementation==$i)][0]
      | .name=$i | .syncLevel="fullSync"
      | (if $id != "" then .id=($id|tonumber) else del(.id) end)
      | .fields |= map(
          if   .name=="prowlarrUrl" then .value="http://prowlarr:9696"
          elif .name=="baseUrl"     then .value=$url
          elif .name=="apiKey"      then .value=$key
          else . end)' <<<"$schema")
    json POST "$PROWLARR/api/v1/applications/test" "$body" "${h[@]}" >/dev/null \
      || { bad "$1 connection test failed"; continue; }
    if [ -n "$id" ]; then
      json PUT "$PROWLARR/api/v1/applications/$id" "$body" "${h[@]}" >/dev/null
    else
      json POST "$PROWLARR/api/v1/applications" "$body" "${h[@]}" >/dev/null
    fi && ok "$1 at $2, full sync, connection tested" || bad "save $1"
  done
  ok "indexers: $(req GET "$PROWLARR/api/v1/indexer" "${h[@]}" | jq length) (left for you to add)"
}

# ------------------------------------------------------------------------ Bazarr
bazarr() {
  echo "Bazarr"
  local key h profiles english status
  key=$(awk '/^auth:/{s=1;next} /^[^ ]/{s=0} s && $1=="apikey:"{print $2}' config/bazarr/config/config.yaml | tr -d "'\"")
  [ -n "$key" ] || { bad "no API key in config/bazarr/config/config.yaml"; return 1; }
  h=(-H "X-API-KEY: $key")

  # Keep any profiles already there; add an English one if it's missing.
  profiles=$(req GET "$BAZARR/api/system/languages/profiles" "${h[@]}") || { bad "read language profiles"; return 1; }
  profiles=$(jq -c 'if any(.[]; .name=="English") then . else
    . + [{profileId: ((map(.profileId) | max // 0) + 1), name: "English", cutoff: null,
          items: [{id: 1, language: "en", audio_exclude: "False", audio_only_include: "False",
                   hi: "False", forced: "False"}],
          mustContain: [], mustNotContain: [], originalFormat: 0, tag: null}] end' <<<"$profiles")
  english=$(jq '[.[] | select(.name=="English")][0].profileId' <<<"$profiles")

  req POST "$BAZARR/api/system/settings" "${h[@]}" \
    --data-urlencode "settings-general-use_sonarr=true" \
    --data-urlencode "settings-sonarr-ip=sonarr" \
    --data-urlencode "settings-sonarr-port=8989" \
    --data-urlencode "settings-sonarr-base_url=/" \
    --data-urlencode "settings-sonarr-ssl=false" \
    --data-urlencode "settings-sonarr-apikey=$SONARR_KEY" \
    --data-urlencode "settings-general-use_radarr=true" \
    --data-urlencode "settings-radarr-ip=radarr" \
    --data-urlencode "settings-radarr-port=7878" \
    --data-urlencode "settings-radarr-base_url=/" \
    --data-urlencode "settings-radarr-ssl=false" \
    --data-urlencode "settings-radarr-apikey=$RADARR_KEY" \
    --data-urlencode "languages-enabled=en" \
    --data-urlencode "languages-profiles=$profiles" \
    --data-urlencode "settings-general-serie_default_enabled=true" \
    --data-urlencode "settings-general-serie_default_profile=$english" \
    --data-urlencode "settings-general-movie_default_enabled=true" \
    --data-urlencode "settings-general-movie_default_profile=$english" >/dev/null \
    || { bad "save settings"; return 1; }
  ok "English profile (id $english), the default for new shows and movies"

  # Bazarr reports the Sonarr/Radarr versions once it has reached them.
  local i
  for i in $(seq 1 15); do
    status=$(req GET "$BAZARR/api/system/status" "${h[@]}" 2>/dev/null) || true
    jq -e '.data.sonarr_version != "" and .data.radarr_version != ""' <<<"$status" >/dev/null 2>&1 && break
    sleep 2
  done
  local sv rv
  sv=$(jq -r '.data.sonarr_version // ""' <<<"$status" 2>/dev/null)
  rv=$(jq -r '.data.radarr_version // ""' <<<"$status" 2>/dev/null)
  [ -n "$sv" ] && ok "connected to Sonarr $sv at sonarr:8989" || bad "Bazarr can't reach Sonarr"
  [ -n "$rv" ] && ok "connected to Radarr $rv at radarr:7878" || bad "Bazarr can't reach Radarr"
}

# ---------------------------------------------------------------------- Jellyfin
jf_auth() { echo "MediaBrowser Client=\"netflixx-configure\", Device=\"stx-server\", DeviceId=\"netflixx-configure\", Version=\"1.0\"${1:+, Token=\"$1\"}"; }

jellyfin() {
  echo "Jellyfin"
  ask JELLYFIN_USER "Jellyfin admin username"
  ask JELLYFIN_PASS "Jellyfin admin password" secret
  local done_ creds token h
  done_=$(req GET "$JELLYFIN/System/Info/Public" | jq -r .StartupWizardCompleted) || { bad "not answering"; return 1; }
  creds=$(jq -n --arg n "$JELLYFIN_USER" --arg p "$JELLYFIN_PASS" '{Name:$n, Password:$p}')
  if [ "$done_" != true ]; then
    json POST "$JELLYFIN/Startup/Configuration" \
      '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}' >/dev/null &&
    req GET "$JELLYFIN/Startup/User" >/dev/null &&
    json POST "$JELLYFIN/Startup/User" "$creds" >/dev/null &&
    json POST "$JELLYFIN/Startup/RemoteAccess" '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' >/dev/null &&
    req POST "$JELLYFIN/Startup/Complete" >/dev/null || { bad "startup wizard"; return 1; }
    ok "startup wizard finished, admin $JELLYFIN_USER created"
  else
    ok "startup wizard was already finished"
  fi

  token=$(json POST "$JELLYFIN/Users/AuthenticateByName" \
    "$(jq -n --arg u "$JELLYFIN_USER" --arg p "$JELLYFIN_PASS" '{Username:$u, Pw:$p}')" \
    -H "Authorization: $(jf_auth)" | jq -r .AccessToken) || { bad "sign in as $JELLYFIN_USER"; return 1; }
  h=(-H "Authorization: $(jf_auth "$token")")

  local folders lib name type path
  folders=$(req GET "$JELLYFIN/Library/VirtualFolders" "${h[@]}") || { bad "read libraries"; return 1; }
  for lib in "Movies movies /data/media/movies" "Shows tvshows /data/media/tv"; do
    read -r name type path <<<"$lib"
    if jq -e --arg p "$path" 'any(.[]; .Locations | index($p))' <<<"$folders" >/dev/null; then
      ok "library $name -> $path (already there)"; continue
    fi
    json POST "$JELLYFIN/Library/VirtualFolders?name=$name&collectionType=$type&refreshLibrary=true" \
      "{\"LibraryOptions\":{\"PathInfos\":[{\"Path\":\"$path\"}]}}" "${h[@]}" >/dev/null \
      && ok "library $name -> $path" || bad "library $name"
  done

  # The Intel render node, found the same way check.sh does.
  local node intel="" enc
  for node in /sys/class/drm/renderD*; do
    [ "$(cat "$node/device/vendor" 2>/dev/null)" = 0x8086 ] && intel="/dev/dri/$(basename "$node")"
  done
  [ -n "$intel" ] || { bad "no Intel render node on this machine"; return 1; }
  enc=$(req GET "$JELLYFIN/System/Configuration/encoding" "${h[@]}") || { bad "read transcoding"; return 1; }
  enc=$(jq --arg d "$intel" '.HardwareAccelerationType="qsv" | .QsvDevice=$d
        | .HardwareDecodingCodecs=["h264","hevc","vp9"]' <<<"$enc")
  json POST "$JELLYFIN/System/Configuration/encoding" "$enc" "${h[@]}" >/dev/null || { bad "save transcoding"; return 1; }
  enc=$(req GET "$JELLYFIN/System/Configuration/encoding" "${h[@]}")
  if [ "$(jq -r '[.HardwareAccelerationType, .QsvDevice, (.HardwareDecodingCodecs|sort|join(","))] | join(" ")' <<<"$enc")" \
       = "qsv $intel h264,hevc,vp9" ]; then
    ok "Intel QuickSync on $intel, hardware decoding H264, HEVC, VP9 (not AV1)"
  else
    bad "transcoding settings didn't stick"
  fi
  req POST "$JELLYFIN/Sessions/Logout" "${h[@]}" >/dev/null || true
}

# ------------------------------------------------------------------------- Seerr
seerr() {
  echo "Seerr"
  local key h ip
  key=$(jq -r .main.apiKey config/seerr/settings.json)
  ip=$(jq -r .jellyfin.ip config/seerr/settings.json)
  h=(-H "X-Api-Key: $key")

  if [ -z "$ip" ]; then
    ask JELLYFIN_USER "Jellyfin admin username"
    ask JELLYFIN_PASS "Jellyfin admin password" secret
    json POST "$SEERR/api/v1/auth/jellyfin" "$(jq -n --arg u "$JELLYFIN_USER" --arg p "$JELLYFIN_PASS" \
      '{username:$u, password:$p, hostname:"jellyfin", port:8096, useSsl:false, urlBase:"", email:"", serverType:2}')" \
      -c "$JAR/seerr" >/dev/null || { bad "sign in with Jellyfin at http://jellyfin:8096"; return 1; }
    ok "signed in with Jellyfin at http://jellyfin:8096 as $JELLYFIN_USER (Seerr admin)"
  else
    ok "Jellyfin already connected at $ip"
  fi

  local libs id
  libs=$(req POST "$SEERR/api/v1/settings/jellyfin/library/sync" "${h[@]}") || { bad "sync Jellyfin libraries"; return 1; }
  for id in $(jq -r '.[] | select(.type=="movie" or .type=="show") | .id' <<<"$libs"); do
    json PUT "$SEERR/api/v1/settings/jellyfin/library/$id" '{"enabled":true}' "${h[@]}" >/dev/null || bad "enable library $id"
  done
  ok "libraries enabled: $(req GET "$SEERR/api/v1/settings/jellyfin/library" "${h[@]}" | jq -r '[.[] | select(.enabled) | .name] | join(", ")')"

  seerr_arr Sonarr sonarr 8989 "$SONARR_KEY" /data/media/tv
  seerr_arr Radarr radarr 7878 "$RADARR_KEY" /data/media/movies

  local init
  init=$(req POST "$SEERR/api/v1/settings/initialize" "${h[@]}" | jq -r .initialized)
  [ "$init" = true ] && ok "setup marked finished" || bad "couldn't mark setup finished"
}

# seerr_arr NAME HOST PORT KEY ROOT  (uses h from seerr)
seerr_arr() {
  local name=$1 host=$2 port=$3 key=$4 root=$5 path=${2}
  local conn test profile body
  if req GET "$SEERR/api/v1/settings/$path" "${h[@]}" | jq -e --arg h "$host" 'any(.[]; .hostname==$h)' >/dev/null; then
    ok "$name already added"; return 0
  fi
  conn=$(jq -n --arg h "$host" --argjson p "$port" --arg k "$key" '{hostname:$h, port:$p, apiKey:$k, useSsl:false, baseUrl:""}')
  test=$(json POST "$SEERR/api/v1/settings/$path/test" "$conn" "${h[@]}") || { bad "$name connection test failed"; return 1; }
  jq -e --arg r "$root" 'any(.rootFolders[]; .path==$r)' <<<"$test" >/dev/null || { bad "$name has no root folder $root"; return 1; }
  # HD-1080p if it exists, else the first quality profile.
  profile=$(jq -c '.profiles | (map(select(.name=="HD-1080p")) + .)[0] | {id, name}' <<<"$test")
  body=$(jq --arg n "$name" --arg r "$root" --argjson pr "$profile" --arg ext "http://stx-server:$port" '. + {
      name:$n, activeProfileId:$pr.id, activeProfileName:$pr.name, activeDirectory:$r,
      tags:[], is4k:false, isDefault:true, externalUrl:$ext, syncEnabled:true, preventSearch:false,
      tagRequests:false}
    + (if $n=="Sonarr" then {activeAnimeProfileId:$pr.id, activeAnimeProfileName:$pr.name,
         activeAnimeDirectory:$r, animeTags:[], enableSeasonFolders:true,
         seriesType:"standard", animeSeriesType:"anime", monitorNewItems:"all"}
       else {minimumAvailability:"released"} end)' <<<"$conn")
  json POST "$SEERR/api/v1/settings/$path" "$body" "${h[@]}" >/dev/null \
    && ok "$name at http://$host:$port, profile $(jq -r .name <<<"$profile"), folder $root" || bad "save $name"
}

# ---------------------------------------------------------------------------------
steps=("$@")
[ ${#steps[@]} -eq 0 ] && steps=(qbittorrent sonarr radarr prowlarr bazarr jellyfin seerr)
for s in "${steps[@]}"; do
  case "$s" in
    qbittorrent|sonarr|radarr|prowlarr|bazarr|jellyfin|seerr) "$s" || failed=1 ;;
    *) echo "Unknown step: $s"; failed=1 ;;
  esac
done

echo
[ "$failed" = 0 ] && echo "All connected." || echo "Something didn't take; see FAIL above."
exit "$failed"
