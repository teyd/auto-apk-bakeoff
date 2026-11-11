#!/usr/bin/env bash
# Summarise every results/*.jsonl into one Markdown table per run and a cross-run tally.
set -euo pipefail
cd "$(dirname "$0")/.."
files=(results/*.jsonl)

echo "## Per run"
for f in "${files[@]}"; do
  echo
  jq -r 'select(.type=="setup") | "### \(.run)  (morphe jar \(.morphe_jar_seconds)s, trawl start \(.trawl_start_seconds)s)"' "$f"
  echo
  echo "| App | Source | Target | Got | Kind | MB | Fetch s | Pin | Version | Patched | APKMirror direct | Error |"
  echo "|---|---|---|---|---|---|---|---|---|---|---|---|"
  jq -r 'select(.type=="result") | [.app, .source, .target, (if .downloaded then "yes" else "no" end),
      (.verify.kind // "-"), ((.verify.size // 0) / 1048576 | floor | tostring), (.download_seconds|tostring),
      (.verify.pin_ok|tostring), (.verify.version_ok|tostring),
      (if .patch.ok then "\(.patch.applied)/\(.expected_patches)" elif .patch.applied then "NO \(.patch.applied)/\(.expected_patches)" else "-" end),
      .apkmirror_direct_http, ((.error // "") | gsub("\\|"; "/") | .[0:80])] | "| " + join(" | ") + " |"' "$f"
done

echo
echo "## Tally (passes = downloaded, pin not false, version ok, patched ok)"
echo
echo "| App | Source | Passes / runs |"
echo "|---|---|---|"
jq -rs 'map(select(.type=="result")) | group_by([.app, .source])[] |
  "| \(.[0].app) | \(.[0].source) | \(map(select(.downloaded and .verify.pin_ok != false and .verify.version_ok and .patch.ok)) | length) / \(length) |"' "${files[@]}"

echo
echo "## Certificates seen (for apps without a pin)"
echo
jq -rs 'map(select(.type=="result" and .verify.certs)) | group_by(.app)[] |
  "- \(.[0].app): " + (map("\(.source)=\(.verify.certs|join(","))") | unique | join("; "))' "${files[@]}"
