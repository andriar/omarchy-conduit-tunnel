#!/usr/bin/env bash
# Start or stop one tunnel as a transient systemd --user service.
#   tunnel-ctl.sh start|stop|restart
# Everything arrives through the environment, so nothing needs shell quoting:
#   TID (8 hex chars), TARGET (user@host or an ssh_config Host), LP (local port),
#   RH (remote host), RP (remote port), and ASKPASS=1 for a tunnel that asks for a password.
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

# Where is the user's ssh-agent? The shell's own SSH_AUTH_SOCK wins; if the shell was
# started without one, look in the usual places (the systemd ssh-agent.socket, GNOME's
# gcr and keyring agents). CONDUIT_AGENT_DIR replaces $XDG_RUNTIME_DIR (used by the tests).
find_agent_socket() {
  if [[ -n ${SSH_AUTH_SOCK:-} && -S $SSH_AUTH_SOCK ]]; then
    echo "$SSH_AUTH_SOCK"
    return 0
  fi
  local dir="${CONDUIT_AGENT_DIR:-${XDG_RUNTIME_DIR:-}}" sock
  [[ -n $dir ]] || return 1
  for sock in "$dir/ssh-agent.socket" "$dir/gcr/ssh" "$dir/keyring/ssh"; do
    if [[ -S $sock ]]; then
      echo "$sock"
      return 0
    fi
  done
  return 1
}

# A password dialog needs the session's display. The shell's own WAYLAND_DISPLAY wins;
# otherwise take the first Wayland socket in the runtime dir.
find_wayland_display() {
  if [[ -n ${WAYLAND_DISPLAY:-} ]]; then
    echo "$WAYLAND_DISPLAY"
    return 0
  fi
  local dir="${CONDUIT_AGENT_DIR:-${XDG_RUNTIME_DIR:-}}" sock
  [[ -n $dir ]] || return 1
  for sock in "$dir"/wayland-[0-9]*; do
    if [[ -S $sock ]]; then
      echo "${sock##*/}"
      return 0
    fi
  done
  return 1
}

start_unit() {
  local target="${TARGET:-}" lp="${LP:-}" rh="${RH:-}" rp="${RP:-}"
  # Validate again here: this script is the last line of defence before ssh runs.
  [[ $target =~ ^[A-Za-z0-9._][A-Za-z0-9._:-]*(@[A-Za-z0-9._:][A-Za-z0-9._:-]*)?$ ]] || fail "invalid SSH server"
  [[ $rh =~ ^[A-Za-z0-9._-]+$ ]] || fail "invalid remote host"
  if ! [[ $lp =~ ^[0-9]+$ ]] || (( 10#$lp < 1024 || 10#$lp > 65535 )); then fail "invalid local port"; fi
  if ! [[ $rp =~ ^[0-9]+$ ]] || (( 10#$rp < 1 || 10#$rp > 65535 )); then fail "invalid remote port"; fi

  stop_unit
  local env_args=()
  # ssh-agent: the user manager does not always know the session's agent socket.
  local agent
  if agent=$(find_agent_socket); then env_args+=("--setenv=SSH_AUTH_SOCK=$agent"); fi

  # Never listen beyond loopback. BatchMode: never hang on a prompt nobody can answer.
  # Restart on failure, but give up after 5 failures in 2 minutes instead of looping forever.
  local batch=yes restart=(-p Restart=on-failure -p "RestartSec=${CONDUIT_RESTART_SEC:-5}" -p StartLimitIntervalSec=120 -p StartLimitBurst=5)
  local auth_opts=()
  if [[ ${ASKPASS:-} == 1 ]]; then
    # "Ask for password": ssh asks through a dialog (askpass.sh), once per attempt.
    # The password is never stored. A failed or dropped tunnel is NOT restarted by itself:
    # a retry loop would pop up the dialog again and again, and a wrong password could
    # lock the account on the server.
    local askpass
    askpass="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/askpass.sh"
    [[ -x $askpass ]] || fail "askpass helper is missing"
    env_args+=("--setenv=SSH_ASKPASS=$askpass" "--setenv=SSH_ASKPASS_REQUIRE=force")
    local wl
    if wl=$(find_wayland_display); then env_args+=("--setenv=WAYLAND_DISPLAY=$wl"); fi
    if [[ -n ${DISPLAY:-} ]]; then env_args+=("--setenv=DISPLAY=$DISPLAY"); fi
    batch=no
    auth_opts=(-o NumberOfPasswordPrompts=1)
    restart=(-p Restart=no)
  fi

  systemd-run --user --quiet --unit="$unit" --description="Conduit tunnel $tid" \
    "${env_args[@]}" \
    "${restart[@]}" \
    "${CONDUIT_SSH_BIN:-ssh}" -N \
    -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
    -o "BatchMode=$batch" -o ConnectTimeout=15 -o ControlMaster=no -o ControlPath=none \
    "${auth_opts[@]}" \
    -L "127.0.0.1:$lp:$rh:$rp" -- "$target"
}

case "$act" in
  start)
    # Starting what already runs must not cut its live connections. "restart" is the way to redo it.
    if systemctl --user is-active --quiet "$unit.service" 2>/dev/null; then echo "already running"; exit 0; fi
    start_unit ;;
  stop) stop_unit ;;
  restart) start_unit ;;
  *) fail "usage: tunnel-ctl.sh start|stop|restart" ;;
esac
