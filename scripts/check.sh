#!/usr/bin/env bash
# Sanity checks, run locally and in CI:  scripts/check.sh
# - manifest.json is valid and every file it points at exists
# - the shared Conduit UI kit still matches ui.lock
# - translations: valid JSON, no unknown keys, every key used in code is defined
# - the shell scripts parse (and pass shellcheck when it is installed)
# - Model.js passes its unit tests (when node is installed)
# - the QML files pass qmllint (syntax)
# - nothing that looks like a profile, key or real host list is committed
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "check: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "jq is required"

jq -e . manifest.json >/dev/null || fail "manifest.json is not valid JSON"
jq -e '.schemaVersion == 1' manifest.json >/dev/null || fail "schemaVersion must be 1"
for field in id name version kinds entryPoints; do
  jq -e --arg f "$field" 'has($f)' manifest.json >/dev/null || fail "manifest.json is missing '$field'"
done
id=$(jq -r .id manifest.json)
[[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "invalid plugin id '$id'"
[[ $id != omarchy.* ]] || fail "plugin id must not use the reserved omarchy.* namespace"
while IFS= read -r entry; do
  [[ -f $entry ]] || fail "manifest entry point not found: $entry"
done < <(jq -r '.entryPoints | to_entries[] | .value' manifest.json)
grep -q "moduleName: \"$id\"" Panel.qml || fail "Panel.qml moduleName does not match manifest id '$id'"

# Shared UI kit (a verified copy of omarchy-conduit-vpn): refresh with scripts/sync-ui.sh.
[[ -f ui.lock ]] || fail "ui.lock is missing"
grep -E '^[0-9a-f]{64}  ' ui.lock | sha256sum -c --quiet 2>/dev/null || fail "a Conduit*.qml component does not match ui.lock (run scripts/sync-ui.sh)"
for f in Conduit*.qml; do
  grep -q -E "^[0-9a-f]{64}  $f$" ui.lock || fail "$f is not listed in ui.lock"
done

# Translations.
for f in i18n/*.json; do jq -e 'type == "object"' "$f" >/dev/null || fail "$f is not a JSON object"; done
[[ -f i18n/en.json ]] || fail "i18n/en.json (the reference catalog) is missing"
for f in i18n/*.json; do
  extra=$(jq -r --slurpfile en i18n/en.json 'keys[] | select(. as $k | ($en[0] | has($k)) | not)' "$f")
  [[ -z $extra ]] || fail "$f has keys that are not in en.json: $extra"
done
# Keys used in code: strings.t("...") in QML, and the catalog keys Model.js returns.
used=$( { grep -o 'strings\.t("[^"]*")' ./*.qml | sed -E 's/.*strings\.t\("([^"]*)"\)/\1/'
          grep -o '"\(reason\|val\|time\)\.[A-Za-z]*"' Model.js | tr -d '"'
          grep -o '"paste\.[A-Za-z.]*"' Model.js | tr -d '"'; } | sort -u)
while IFS= read -r key; do
  [[ -z $key ]] && continue
  jq -e --arg k "$key" 'has($k)' i18n/en.json >/dev/null || fail "code uses the string key \"$key\" but en.json does not define it"
done <<<"$used"

# Shell scripts.
for s in scripts/*.sh tests/*.sh; do bash -n "$s" || fail "$s has a syntax error"; done
if command -v shellcheck >/dev/null; then
  shellcheck -x scripts/*.sh tests/*.sh || fail "shellcheck found problems"
fi

# Unit tests.
if command -v node >/dev/null; then
  node tests/model.test.js >/dev/null || fail "tests/model.test.js failed (run it to see why)"
else
  echo "check: node not found, skipping tests/model.test.js"
fi
bash tests/askpass.test.sh >/dev/null || fail "tests/askpass.test.sh failed (run it to see why)"

# QML: qmllint catches syntax errors (a stray brace in a 1000-line panel). The Omarchy modules (qs.*)
# are not installed here, so it cannot check types or property names, only the shape of the code.
# CI sets REQUIRE_QMLLINT=1 so a missing qmllint fails there instead of being skipped.
qmllint_bin=""
for c in qmllint6 qmllint /usr/lib/qt6/bin/qmllint /usr/lib/x86_64-linux-gnu/qt6/bin/qmllint; do
  if command -v "$c" >/dev/null 2>&1; then qmllint_bin=$(command -v "$c"); break; fi
done
if [[ -n $qmllint_bin ]]; then
  if ! lint_out=$(timeout 120 "$qmllint_bin" ./*.qml 2>&1); then
    printf '%s\n' "$lint_out" | tail -25 >&2
    fail "qmllint reported a problem (run: qmllint ./*.qml)"
  fi
elif [[ ${REQUIRE_QMLLINT:-} == 1 ]]; then
  fail "qmllint is required but not installed"
else
  echo "check: qmllint not found, skipping it"
fi

# Secret / profile scan.
pattern='BEGIN (RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY|BEGIN CERTIFICATE|IdentityFile +[^ ]|\.rds\.amazonaws\.com|\.internal\.[a-z]+\b'
if git ls-files --cached --others --exclude-standard -z | xargs -0 grep -I -n -E -e "$pattern" -- 2>/dev/null \
    | grep -v -E '^(scripts/check\.sh|README\.md|CONTRIBUTING\.md|i18n/[a-z-]+\.json|tests/model\.test\.js|tests/e2e-real-ssh\.sh|Panel\.qml):'; then
  fail "found text that looks like a private key or a real host"
fi
if git ls-files --cached --others --exclude-standard | grep -E '(^|/)tunnels\.json$|\.(pem|key|crt|p12)$'; then
  fail "a tunnel list or key file is tracked"
fi

echo "check: ok ($id)"
