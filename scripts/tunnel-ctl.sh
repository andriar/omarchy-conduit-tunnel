#!/usr/bin/env bash
# Start or stop one tunnel as a transient systemd --user service.
#   tunnel-ctl.sh start|stop|restart
# Everything arrives through the environment, so nothing needs shell quoting:
#   TID (8 hex chars), TARGET (user@host or an ssh_config Host), LP (local port),
#   RH (remote host), RP (remote port).
# CONDUIT_SSH_BIN and CONDUIT_RESTART_SEC override the ssh binary and the restart delay (used by the tests).
set -u

fail() { echo "$*" >&2; exit 2; }

act="${1:-}"
tid="${TID:-}"
[[ $tid =~ ^[0-9a-f]{8}$ ]] || fail "invalid tunnel id"
unit="conduit-tunnel-$tid"

stop_unit() {
  systemctl --user stop "$unit.service" 2>/dev/null
  systemctl --user reset-failed "$unit.service" 2>/dev/null
  return 0
}

start_unit() {
  local target="${TARGET:-}" lp="${LP:-}" rh="${RH:-}" rp="${RP:-}"
  # Validate again here: this script is the last line of defence before ssh runs.
  [[ $target =~ ^[A-Za-z0-9._][A-Za-z0-9._:-]*(@[A-Za-z0-9._:-]+)?$ ]] || fail "invalid SSH server"
  [[ $rh =~ ^[A-Za-z0-9._-]+$ ]] || fail "invalid remote host"
  if ! [[ $lp =~ ^[0-9]+$ ]] || (( lp < 1024 || lp > 65535 )); then fail "invalid local port"; fi
  if ! [[ $rp =~ ^[0-9]+$ ]] || (( rp < 1 || rp > 65535 )); then fail "invalid remote port"; fi

  stop_unit
  local env_args=()
  # ssh-agent: the user manager does not always know the session's agent socket.
  [[ -n ${SSH_AUTH_SOCK:-} ]] && env_args+=("--setenv=SSH_AUTH_SOCK=$SSH_AUTH_SOCK")

  # Never listen beyond loopback. BatchMode: never hang on a prompt nobody can answer.
  # Restart on failure, but give up after 5 failures in 2 minutes instead of looping forever.
  systemd-run --user --quiet --unit="$unit" --description="Conduit tunnel $tid" \
    "${env_args[@]}" \
    -p Restart=on-failure -p RestartSec="${CONDUIT_RESTART_SEC:-5}" -p StartLimitIntervalSec=120 -p StartLimitBurst=5 \
    "${CONDUIT_SSH_BIN:-ssh}" -N \
    -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
    -o BatchMode=yes -o ConnectTimeout=15 -o ControlMaster=no -o ControlPath=none \
    -L "127.0.0.1:$lp:$rh:$rp" -- "$target"
}

case "$act" in
  start) start_unit ;;
  stop) stop_unit ;;
  restart) start_unit ;;
  *) fail "usage: tunnel-ctl.sh start|stop|restart" ;;
esac
