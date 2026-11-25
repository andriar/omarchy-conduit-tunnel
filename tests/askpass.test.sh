#!/usr/bin/env bash
# Unit test of scripts/askpass.sh with a fake zenity. No display, no ssh.
#   tests/askpass.test.sh
set -u
cd "$(dirname "$0")/.." || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export CONDUIT_ZENITY_BIN="$tmp/zenity" ZLOG="$tmp/zenity.log"
# Records its arguments; prints "hunter2" like a dialog the user filled in, or exits 1 like Cancel.
cat >"$tmp/zenity" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$ZLOG"
[[ -n ${ZCANCEL:-} ]] && exit 1
echo hunter2
FAKE
chmod +x "$tmp/zenity"

pass=0
fail=0
check() { # check "name" command args...
  local name=$1
  shift
  if "$@"; then pass=$((pass + 1)); echo "PASS $name"; else fail=$((fail + 1)); echo "FAIL $name"; fi
}
ask() { rm -f "$ZLOG"; bash scripts/askpass.sh "$1"; }
zenity_ran() { [[ -f $ZLOG ]]; }
zenity_text() { grep -- '^--text=' "$ZLOG"; }

# a password prompt opens the dialog and returns what was typed
out=$(ask "user@host.example's password: ")
check "password prompt: answer is passed on" test "$out" = hunter2
check "password prompt: input is hidden" grep -qx -- '--hide-text' "$ZLOG"
check "password prompt: markup is off" grep -qx -- '--no-markup' "$ZLOG"
check "password prompt: dialog has a timeout" grep -qx -- '--timeout=120' "$ZLOG"

# a host-key question is never answered, with or without the OpenSSH 8.4+ hint
rm -f "$ZLOG"
SSH_ASKPASS_PROMPT=confirm bash scripts/askpass.sh "Are you sure you want to continue connecting (yes/no/[fingerprint])? "
check "confirm prompt: refused (exit 1)" test $? -eq 1
check "confirm prompt: no dialog" bash -c "! test -f '$ZLOG'"
rm -f "$ZLOG"
bash scripts/askpass.sh "Are you sure you want to continue connecting (yes/no/[fingerprint])? " >/dev/null
check "yes/no text without the hint: refused (exit 1)" test $? -eq 1
check "yes/no text without the hint: no dialog" bash -c "! test -f '$ZLOG'"

# informational messages are ignored
rm -f "$ZLOG"
out=$(SSH_ASKPASS_PROMPT=none bash scripts/askpass.sh "Authenticated to host")
check "info prompt: exit 0, empty answer" test -z "$out"
check "info prompt: no dialog" bash -c "! test -f '$ZLOG'"

# prompt text from a server cannot inject markup or odd characters into the dialog
ask "<b>x</b> & \$(id) \`id\` \"q\" password: " >/dev/null
check "hostile prompt: only plain characters are shown" test "$(zenity_text)" = "--text=bxb  id id q password: "

# an empty prompt still gets a sensible label
ask "" >/dev/null
check "empty prompt: default label" test "$(zenity_text)" = "--text=SSH password"

# Cancel (or the timeout) means no password: exit 1
ZCANCEL=1 bash scripts/askpass.sh "password: " >/dev/null
check "cancelled dialog: exit 1" test $? -eq 1

echo
echo "$pass passed, $fail failed"
exit $((fail > 0))
