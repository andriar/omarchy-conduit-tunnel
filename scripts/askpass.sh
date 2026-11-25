#!/usr/bin/env bash
# SSH_ASKPASS helper for tunnels with "Ask for password" turned on (see tunnel-ctl.sh).
# ssh runs this with the prompt as $1 and reads the answer from stdout.
#
# What it will and will not answer:
#   - a password / passphrase / one-time code prompt -> a dialog asks you; nothing is stored
#   - a yes/no question (an unknown host key)        -> always refused, never auto-answered,
#                                                       so host key checking is not weakened
#   - an informational message                       -> ignored
# Cancelling the dialog, or waiting two minutes, makes ssh fail with "Permission denied".
# CONDUIT_ZENITY_BIN replaces zenity (used by the tests).
set -u

prompt="${1:-}"

# OpenSSH 8.4+ says what kind of prompt this is.
case "${SSH_ASKPASS_PROMPT:-}" in
  confirm) exit 1 ;;
  none) exit 0 ;;
esac
# Older OpenSSH sets no such variable: refuse anything that reads like a yes/no question.
if grep -qiE '\(yes/no|continue connecting|are you sure' <<<"$prompt"; then exit 1; fi

# The prompt text can come from the server (keyboard-interactive), so show only plain
# characters, and never let the dialog interpret markup.
shown=$(printf '%s' "$prompt" | tr -cd "A-Za-z0-9@._:' -" | cut -c1-120)
[[ -n $shown ]] || shown="SSH password"

exec "${CONDUIT_ZENITY_BIN:-zenity}" --entry --hide-text --no-markup \
  --title="Conduit Tunnel" --text="$shown" --timeout=120
