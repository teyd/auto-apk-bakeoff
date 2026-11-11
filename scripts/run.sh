#!/usr/bin/env bash
# Bake-off: for each app, ask Morphe for the target version, fetch it from each
# source, verify it, patch it, and append one JSON line per (app, source) to
# results/<run>.jsonl.
#
# Env: ONLY="x youtube"  SOURCES="apkpure apkmirror"  HOST_LABEL=name  KEEP=1 (keep files)
# Needs: java 21, apksigner, aapt2, apkeep, gh, jq, python3, docker, curl.
set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$HERE/work}
RESULTS=${RESULTS:-$HERE/results}
HOST_LABEL=${HOST_LABEL:-$(hostname -s)}
SOURCES=${SOURCES:-"apkpure apkmirror"}
ONLY=${ONLY:-}
ARCH=arm64-v8a
MORPHE_VERSION=2.1.1
MORPHE_SHA256=3a2efefd567b44dde15971a58d5aa649a32aba30781d3400dc08d688c720168f
TRAWL_IMAGE=ghcr.io/germondai/trawl:1.11.0@sha256:ef732d2c62724fe4ed110316559340d3adc1edfaae697e173c18a1251613a781
export TRAWL_URL=${TRAWL_URL:-http://127.0.0.1:8191}
UA='Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0'

RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)-$HOST_LABEL
OUT=$RESULTS/$RUN_ID.jsonl
mkdir -p "$WORK" "$RESULTS"
now() { date +%s.%N; }
since() { awk -v a="$1" -v b="$(now)" 'BEGIN { printf "%.1f", b - a }'; }
emit() { jq -cn "$@" >>"$OUT"; }

# ---- setup: Morphe jar and trawl, timed ----------------------------------------
JAR=$WORK/morphe/morphe-desktop-$MORPHE_VERSION-all.jar
t=$(now)
if [ ! -f "$JAR" ]; then
  gh release download "v$MORPHE_VERSION" -R MorpheApp/morphe-desktop -p '*-all.jar' -D "$WORK/morphe" --clobber
fi
echo "$MORPHE_SHA256  $JAR" | sha256sum -c --quiet || { echo "morphe jar hash mismatch" >&2; exit 1; }
morphe_s=$(since "$t")

trawl_started=false
trawl_s=0
if [[ " $SOURCES " == *" apkmirror "* ]] && ! curl -sf "$TRAWL_URL/health" >/dev/null; then
  t=$(now)
  docker rm -f bakeoff-trawl >/dev/null 2>&1
  docker run -d --name bakeoff-trawl -p 127.0.0.1:8191:8191 --shm-size=1gb \
    -e SESSION_CACHE_DRIVER=memory -e BROWSER_POOL_SIZE=1 "$TRAWL_IMAGE" >/dev/null
  for _ in $(seq 180); do curl -sf "$TRAWL_URL/health" >/dev/null && break; sleep 1; done
  trawl_s=$(since "$t")
  trawl_started=true
fi
emit --arg run "$RUN_ID" --arg host "$HOST_LABEL" --argjson morphe "$morphe_s" --argjson trawl "$trawl_s" \
  --arg java "$(java -version 2>&1 | head -1)" --arg apkeep "$(apkeep --version 2>&1)" \
  '{type:"setup", run:$run, host:$host, morphe_jar_seconds:$morphe, trawl_start_seconds:$trawl, java:$java, apkeep:$apkeep}'

# ---- per app --------------------------------------------------------------------
jq -c '.[]' "$HERE/apps.json" | while read -r app; do
  id=$(jq -r .id <<<"$app"); pkg=$(jq -r .package <<<"$app"); repo=$(jq -r .patches <<<"$app")
  am_url=$(jq -r .apkmirror <<<"$app"); pin=$(jq -r '.pin // ""' <<<"$app")
  [ -n "$ONLY" ] && [[ " $ONLY " != *" $id "* ]] && continue
  echo "=== $id" >&2

  tag=$(gh release view -R "$repo" --json tagName -q .tagName)
  bdir=$WORK/bundles/${repo//\//__}/$tag
  if ! ls "$bdir"/*.mpp >/dev/null 2>&1; then
    gh release download "$tag" -R "$repo" -p 'patches*.mpp' -D "$bdir" --clobber
  fi
  mpp=$(ls "$bdir"/*.mpp | head -1)

  # Target: most patches, newest version on ties.
  lv=$(java -jar "$JAR" list-versions --patches "$mpp" -f "$pkg" 2>&1 </dev/null)
  ranked=$(printf '%s\n' "$lv" | sed -nE 's/^\t(.*) \(([0-9]+) patch(es)?\)$/\2\t\1/p' \
    | sed -E 's/ \[versionCodes:[^]]*\]//' | sort -t$'\t' -k1,1nr -k2,2Vr)
  expected=$(head -1 <<<"$ranked" | cut -f1)
  target=$(head -1 <<<"$ranked" | cut -f2)
  if [ -z "$target" ]; then
    emit --arg run "$RUN_ID" --arg app "$id" --arg lv "$lv" '{type:"app", run:$run, app:$app, error:"list-versions gave no version", list_versions:$lv}'
    continue
  fi

  direct=$(curl -s -o /dev/null -w '%{http_code}' -A "$UA" "$am_url")

  for src in $SOURCES; do
    dir=$WORK/dl/$id/$src; rm -rf "$dir"; mkdir -p "$dir"
    file=""; fetch='{}'; err=""
    t=$(now)
    case $src in
      apkpure)
        # APKPure has served modified apps; the certificate pin in verify.py is the guard.
        log=$(apkeep -d apk-pure -o "acknowledge_dangers=true,arch=$ARCH" -a "$pkg@$target" "$dir" 2>&1)
        file=$(find "$dir" -maxdepth 1 -type f | head -1)
        [ -z "$file" ] && err="apkeep: $(tail -c 300 <<<"$log")"
        ;;
      apkmirror)
        fetch=$(python3 -I "$HERE/scripts/fetch_apkmirror.py" "$am_url" "$target" "$ARCH" "$dir" 2>&1 | tail -1)
        jq -e . >/dev/null 2>&1 <<<"$fetch" || fetch=$(jq -cn --arg e "$fetch" '{error:$e}')
        file=$(jq -r '.file // ""' <<<"$fetch")
        err=$(jq -r '.error // ""' <<<"$fetch")
        ;;
    esac
    dl_s=$(since "$t")

    verify='{}'; patch='{}'
    if [ -n "$file" ] && [ -f "$file" ]; then
      verify=$(python3 -I "$HERE/scripts/verify.py" "$file" "$pkg" "$target" "$pin" 2>&1 | tail -1)
      jq -e . >/dev/null 2>&1 <<<"$verify" || verify=$(jq -cn --arg e "$verify" '{error:$e}')
      # Patch even when verification fails, so both questions get an answer.
      pdir=$WORK/patch/$id/$src; rm -rf "$pdir"; mkdir -p "$pdir"
      t=$(now)
      plog=$(java -Xmx4g -jar "$JAR" patch -p "$mpp" --striplibs "$ARCH" -t "$pdir/tmp" --unsigned \
        -o "$pdir/out.apk" -r "$pdir/result.json" "$(realpath "$file")" 2>&1 </dev/null)
      prc=$?
      p_s=$(since "$t")
      if [ -f "$pdir/result.json" ]; then
        patch=$(jq -c --argjson exp "$expected" --argjson rc $prc --argjson s "$p_s" \
          '{exit:$rc, seconds:$s, success, applied:(.appliedPatches|length), expected:$exp,
            failed:.failedPatches, ok:(.success and (.failedPatches|length)==0 and (.appliedPatches|length)==$exp)}' \
          "$pdir/result.json")
      else
        patch=$(jq -cn --argjson rc $prc --argjson s "$p_s" --arg log "$(tail -c 600 <<<"$plog")" \
          '{exit:$rc, seconds:$s, ok:false, log:$log}')
      fi
      [ -z "${KEEP:-}" ] && rm -rf "$pdir"
    fi
    [ -z "${KEEP:-}" ] && rm -rf "$dir"

    emit --arg run "$RUN_ID" --arg host "$HOST_LABEL" --arg app "$id" --arg src "$src" --arg target "$target" \
      --arg tag "$tag" --argjson exp "$expected" --arg ranked "$ranked" --arg direct "$direct" \
      --argjson dl "$dl_s" --arg err "$err" --argjson fetch "$fetch" --argjson verify "$verify" --argjson patch "$patch" \
      '{type:"result", run:$run, host:$host, app:$app, source:$src, patches_tag:$tag, target:$target,
        expected_patches:$exp, candidates:($ranked|split("\n")), apkmirror_direct_http:$direct,
        downloaded:($err=="" and ($verify|has("kind"))), download_seconds:$dl, error:(if $err=="" then null else $err end),
        fetch:$fetch, verify:$verify, patch:$patch}'
    jq -r 'select(.type=="result") | "  \(.source): dl=\(.downloaded) \(.download_seconds)s kind=\(.verify.kind) pin=\(.verify.pin_ok) ver=\(.verify.version_ok) patch=\(.patch.ok) \(.patch.applied)/\(.expected_patches) \(.error // "")"' <<<"$(tail -1 "$OUT")" >&2
  done
done

if [ -n "${CI:-}" ]; then
  # Results go to the log (artifact storage may be full).
  echo "::group::results jsonl"; cat "$OUT"; echo "::endgroup::"
  $trawl_started && { echo "::group::trawl log"; docker logs --tail 200 bakeoff-trawl 2>&1; echo "::endgroup::"; }
fi
$trawl_started && docker rm -f bakeoff-trawl >/dev/null
echo "results: $OUT" >&2
