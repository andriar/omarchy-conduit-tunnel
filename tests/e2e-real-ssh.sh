#!/usr/bin/env bash
# End-to-end test with REAL ssh: a private sshd on 127.0.0.1:22222 (run as you, temporary keys),
# a passphrase-protected key, a private ssh-agent, and a fake "database" on 127.0.0.1:45950.
# It proves the whole chain: host key check, login through the agent, and data flowing through
# the forward. Needs sshd, ssh, ssh-agent, python3 and a systemd user session. Nothing is
# installed or enabled: every process and file is temporary and removed on exit.
#   tests/e2e-real-ssh.sh
# The predicates are passed by name to check/poll_until, so shellcheck sees them as unused.
# shellcheck disable=SC2329
set -u
cd "$(dirname "$0")/.." || exit 1

SSHD_PORT=22222
DB_PORT=45950
TUN_PORT=45951
ID=a1b2c3f1
T=$(mktemp -d)
PIDS=()
pass=0
fail=0

check() {
  local name=$1
  shift
  if "$@"; then pass=$((pass + 1)); echo "PASS $name"; else fail=$((fail + 1)); echo "FAIL $name"; fi
}
poll_until() {
  local tries=$1 _
  shift
  for _ in $(seq 1 "$tries"); do "$@" && return 0; sleep 0.5; done
  return 1
}
ctl() { TID=$ID TARGET=testbastion LP=$TUN_PORT RH=127.0.0.1 RP=$DB_PORT bash scripts/tunnel-ctl.sh "$1"; }
col() { SPECS="$ID:$TUN_PORT" bash scripts/tunnel-status.sh | cut -f"$1"; }
is_failed() { [[ $(col 3) == failed ]]; }
is_up() { [[ $(col 3) == active && $(col 7) == 1 ]]; }
is_stopped() { [[ $(col 3) == inactive && $(col 7) == 0 ]]; }
reason_has() { [[ $(col 8) == *"$1"* ]]; }
through_tunnel() { # the banner the fake database prints, read through the forward
  python3 -c "
import socket
s = socket.create_connection(('127.0.0.1', $TUN_PORT), timeout=5)
print(s.recv(64).decode().strip())" 2>/dev/null
}

cleanup() {
  ctl stop >/dev/null 2>&1
  local p
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
  rm -rf "$T"
}
trap cleanup EXIT

for port in "$SSHD_PORT" "$DB_PORT" "$TUN_PORT"; do
  if ss -H -ltn "sport = :$port" | grep -q .; then echo "port $port is in use; stop whatever uses it and retry"; exit 1; fi
done

# --- the world: host key, a passphrase-protected user key, sshd, a fake database ----------
ssh-keygen -q -t ed25519 -N '' -f "$T/host"
ssh-keygen -q -t ed25519 -N 'e2e-passphrase' -f "$T/id"
cp "$T/id.pub" "$T/authorized_keys"
/usr/bin/sshd -D -e -f /dev/null -p "$SSHD_PORT" -h "$T/host" -o ListenAddress=127.0.0.1 \
  -o AuthorizedKeysFile="$T/authorized_keys" -o PidFile=none -o UsePAM=no \
  -o PasswordAuthentication=no -o StrictModes=no -o LogLevel=ERROR \
  -o PerSourcePenalties=no >"$T/sshd.log" 2>&1 &   # (the failing scenarios would otherwise get this client banned)
PIDS+=($!)
python3 -c "
import socket, threading
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('127.0.0.1', $DB_PORT)); srv.listen(5)
while True:
    c, _ = srv.accept(); c.sendall(b'hello-from-the-database\n'); c.close()" &
PIDS+=($!)
sleep 1.5

cat > "$T/ssh_config" <<CONF
Host testbastion
  HostName 127.0.0.1
  Port $SSHD_PORT
  User $(id -un)
  IdentityFile $T/id
  IdentitiesOnly yes
  UserKnownHostsFile $T/known_hosts
  GlobalKnownHostsFile /dev/null
CONF
printf '#!/usr/bin/env bash\nexec ssh -F "%s" "$@"\n' "$T/ssh_config" > "$T/ssh-wrapper"
chmod +x "$T/ssh-wrapper"
export CONDUIT_SSH_BIN="$T/ssh-wrapper" CONDUIT_RESTART_SEC=1 CONDUIT_AGENT_DIR="$T"
unset SSH_AUTH_SOCK

# 1. a host key nobody has trusted yet is refused (never auto-accepted)
ctl start
check "unknown host key: ends up failed" poll_until 40 is_failed
check "unknown host key: reason says Host key verification" reason_has "Host key verification"
ctl stop

# 2. host trusted, but the key has a passphrase and no agent holds it
echo "[127.0.0.1]:$SSHD_PORT $(cut -d' ' -f1,2 "$T/host.pub")" > "$T/known_hosts"
ctl start
check "passphrase key without an agent: ends up failed" poll_until 40 is_failed
check "passphrase key without an agent: reason says Permission denied" reason_has "Permission denied"
ctl stop

# 3. an agent holds the key; the tunnel finds it by itself (no SSH_AUTH_SOCK in the environment)
ssh-agent -D -a "$T/ssh-agent.socket" >/dev/null 2>&1 &
PIDS+=($!)
sleep 0.5
printf '#!/bin/sh\necho e2e-passphrase\n' > "$T/askpass"
chmod +x "$T/askpass"
SSH_AUTH_SOCK="$T/ssh-agent.socket" SSH_ASKPASS="$T/askpass" SSH_ASKPASS_REQUIRE=force ssh-add "$T/id" </dev/null >/dev/null 2>&1
check "the agent holds the key" test "$(SSH_AUTH_SOCK="$T/ssh-agent.socket" ssh-add -l 2>/dev/null | wc -l)" -eq 1
ctl start
check "with the agent: tunnel comes up" poll_until 40 is_up
if ! is_up; then
  echo "--- diagnostics (the tunnel did not come up) ---"
  systemctl --user show "conduit-tunnel-$ID.service" -p ActiveState -p SubState -p Environment | cut -c1-200
  journalctl --user -u "conduit-tunnel-$ID.service" -n 12 --no-pager -o cat 2>/dev/null | cut -c1-200
  echo "--- end diagnostics ---"
fi
check "bound to 127.0.0.1 only" test "$(ss -H -ltn "sport = :$TUN_PORT" | awk '{print $4}')" = "127.0.0.1:$TUN_PORT"
check "data flows through the forward" test "$(through_tunnel)" = hello-from-the-database

# 4. stopping closes the port
ctl stop
check "stop: port released and unit inactive" poll_until 10 is_stopped

echo
echo "$pass passed, $fail failed"
exit $(( fail > 0 ))
