#!/usr/bin/env bash
# Copy the shared Conduit UI kit (Conduit*.qml + ui.lock) from the source-of-truth repo into this plugin.
#   scripts/sync-ui.sh [git-ref]      # default: main; use a tag to pin a version
# Every file is checked against the downloaded ui.lock before anything is written.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "sync-ui: $*" >&2; exit 1; }

repo="andriar/omarchy-conduit-vpn"
ref="${1:-main}"
[[ $ref =~ ^[A-Za-z0-9._/-]+$ ]] || fail "invalid ref '$ref'"
# CONDUIT_UI_BASE overrides the download location (a fork, or file:///path for testing).
base="${CONDUIT_UI_BASE:-https://raw.githubusercontent.com/$repo/$ref}"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$base/ui.lock" -o "$tmp/ui.lock" || fail "could not download ui.lock from $repo@$ref"

files=()
while read -r _ file; do
  [[ $file =~ ^Conduit[A-Za-z0-9]*\.qml$ ]] || fail "unexpected file name in ui.lock: $file"
  curl -fsSL "$base/$file" -o "$tmp/$file" || fail "could not download $file"
  files+=("$file")
done < <(grep -E '^[0-9a-f]{64}  ' "$tmp/ui.lock")
[[ ${#files[@]} -gt 0 ]] || fail "ui.lock lists no components"

(cd "$tmp" && grep -E '^[0-9a-f]{64}  ' ui.lock | sha256sum -c --quiet) || fail "downloaded files do not match ui.lock"

for f in "${files[@]}"; do cp "$tmp/$f" .; done
cp "$tmp/ui.lock" .
echo "sync-ui: $(awk '/^version /{print "version " $2}' ui.lock) from $repo@$ref (${#files[@]} components)"
