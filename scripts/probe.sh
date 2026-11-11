#!/usr/bin/env bash
# One-off probe: which route reaches each page from this machine's IP?
# Routes: plain curl, FlareSolverr (FLARESOLVERR_URL), trawl (TRAWL_URL, if up).
# Also downloads YouTube 21.30.216 from Uptodown and archive.org and checks it.
set -uo pipefail
FS=${FLARESOLVERR_URL:-http://127.0.0.1:8191}
TR=${TRAWL_URL:-}
UA='Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0'
B=https://www.apkmirror.com
URLS=(
  "$B/apk/instagram/instagram-instagram/"
  "$B/apk/discord/discord-chat-for-gamers/"
  "$B/apk/google-inc/gboard/gboard-the-google-keyboard-18-5-4-993608717-release/"
  "$B/apk/google-inc/youtube/youtube-21-30-216-release/"
  "$B/apk/x-corp/twitter/"
  "$B/apk/instagram/instagram-instagram/feed/"
)
title() { grep -oE '<title>[^<]{0,50}' | head -1 | sed 's/<title>//'; }

echo "| URL | curl | FlareSolverr | trawl |"
echo "|---|---|---|---|"
for u in "${URLS[@]}"; do
  c=$(curl -s -A "$UA" -o /tmp/p.html -w '%{http_code}' "$u"); ct=$(title </tmp/p.html)
  t0=$(date +%s)
  curl -s -X POST "$FS/v1" -H 'Content-Type: application/json' \
    -d "{\"cmd\":\"request.get\",\"url\":\"$u\",\"maxTimeout\":60000}" -o /tmp/fs.json
  f="$(jq -r '"\(.status) \(.solution.status // "-")"' /tmp/fs.json 2>/dev/null) $(jq -r '.solution.response // ""' /tmp/fs.json | title) $(( $(date +%s) - t0 ))s"
  [ "$(jq -r .status /tmp/fs.json 2>/dev/null)" != ok ] && f="$f $(jq -r '.message // ""' /tmp/fs.json | head -c 120)"
  tr="-"
  if [ -n "$TR" ]; then
    t0=$(date +%s)
    curl -s -X POST "$TR/scrape" -H 'Content-Type: application/json' -d "{\"url\":\"$u\",\"solveEmbeddedCaptchas\":false}" -o /tmp/tr.json
    tr="$(jq -r '"\(.statusCode) tier=\(.tier)"' /tmp/tr.json) $(jq -r '.html // ""' /tmp/tr.json | title) $(( $(date +%s) - t0 ))s"
  fi
  echo "| ${u#$B} | $c $ct | $f | $tr |"
  sleep 3
done

echo
echo "YouTube 21.30.216 from other sources:"
mkdir -p /tmp/yt
t0=$(date +%s)
curl -sL -A "$UA" -o /tmp/yt/archive.apk -w "archive.org: http=%{http_code} size=%{size_download}" \
  https://archive.org/download/jhc-apks/apks/com.google.android.youtube/com.google.android.youtube-21.30.216-all.apk
echo " $(( $(date +%s) - t0 ))s $(apksigner verify --print-certs /tmp/yt/archive.apk 2>/dev/null | grep -c 3d7a1223019aa39d9ea0e3436ab7c0896bfb4fb679f4de5fe7c23f326c8f994a) pin-lines"

base=https://youtube.en.uptodown.com/android
t0=$(date +%s)
code=$(curl -s -A "$UA" "$base/versions" | grep -oE 'data-code="[0-9]+"' | head -1 | grep -oE '[0-9]+')
vurl=""
for i in $(seq 1 6); do
  vurl=$(curl -s -A "$UA" "$base/apps/$code/versions/$i" | jq -r '.data[] | select(.version=="21.30.216") | .versionURL | "\(.url)/\(.extraURL)/\(.versionID)"' 2>/dev/null | head -1)
  [ -n "$vurl" ] && break
done
dl=$(curl -s -A "$UA" "$vurl" | grep -oE 'id="detail-download-button"[^>]*' | grep -oE 'data-url="[^"]+"' | head -1 | cut -d'"' -f2)
curl -sL -A "$UA" -o /tmp/yt/uptodown.apk -w "uptodown: http=%{http_code} size=%{size_download}" "https://dw.uptodown.com/dwn/$dl"
echo " $(( $(date +%s) - t0 ))s $(apksigner verify --print-certs /tmp/yt/uptodown.apk 2>/dev/null | grep -c 3d7a1223019aa39d9ea0e3436ab7c0896bfb4fb679f4de5fe7c23f326c8f994a) pin-lines"
