#!/usr/bin/env bash
# End-to-end test of the shell scripts against real systemd --user units, with a fake ssh.
# Needs a systemd user session. Uses ports 45931-45938 and units conduit-tunnel-a1b2c30*.
#   tests/e2e-local.sh
# The predicates below are passed by name to check/poll_until, so shellcheck sees them as unused.
# shellcheck disable=SC2329
set -u
cd "$(dirname "$0")/.." || exit 1
export CONDUIT_SSH_BIN="$PWD/tests/fake-ssh.sh" CONDUIT_RESTART_SEC=1

pass=0
fail=0
FOREIGN_PID=""
# Tunnel ids are 8 hex digits.
ids=(a1b2c301 a1b2c302 a1b2c303 a1b2c304 a1b2c305 a1b2c306 a1b2c307 a1b2c308)

check() { # check "name" command args...
  local name=$1
  shift
  if "$@"; then
    pass=$((pass + 1)); echo "PASS $name"
  else
    fail=$((fail + 1)); echo "FAIL $name"
  fi
}

ctl() { # ctl id target local-port start|stop|restart
  TID=$1 TARGET=$2 LP=$3 RH=db.example RP=5432 bash scripts/tunnel-ctl.sh "$4"
}
status() { SPECS="$1:$2" bash scripts/tunnel-status.sh; }
col() { status "$1" "$2" | cut -f"$3"; }   # col id port column

poll_until() { # poll_until tries command args...
  local tries=$1
  shift
  local _
  for _ in $(seq 1 "$tries"); do
    "$@" && return 0
    sleep 0.5
  done
  return 1
}

# Predicates, each taking: id port
is_listening() { [[ $(col "$1" "$2" 7) == 1 ]]; }
is_stopped() { [[ $(col "$1" "$2" 3) == inactive && $(col "$1" "$2" 7) == 0 ]]; }
is_failed() { [[ $(col "$1" "$2" 3) == failed ]]; }
is_running_and_listening() { [[ $(col "$1" "$2" 3) == active && $(col "$1" "$2" 7) == 1 ]]; }
reason_has() { [[ $(col "$1" "$2" 8) == *"$3"* ]]; }

cleanup() {
  local i
  for i in "${ids[@]}"; do TID=$i bash scripts/tunnel-ctl.sh stop >/dev/null 2>&1; done
  if [[ -n $FOREIGN_PID ]]; then kill "$FOREIGN_PID" 2>/dev/null; fi
}
trap cleanup EXIT

# 1. a working tunnel comes up, listens on loopback only, restarts and stops cleanly
check "start returns 0" ctl "${ids[0]}" ok 45931 start
check "listening after start" poll_until 20 is_listening "${ids[0]}" 45931
check "unit is active" test "$(col "${ids[0]}" 45931 3)" = active
check "start time recorded" test "$(col "${ids[0]}" 45931 6)" -gt 1700000000
check "bound to 127.0.0.1 only" test "$(ss -H -ltn 'sport = :45931' | awk '{print $4}')" = 127.0.0.1:45931
check "restart works" ctl "${ids[0]}" ok 45931 restart
check "listening again after restart" poll_until 20 is_listening "${ids[0]}" 45931
check "stop works" ctl "${ids[0]}" ok 45931 stop
check "stop: inactive and port released" poll_until 10 is_stopped "${ids[0]}" 45931

# 2. failures end as 'failed' with a readable reason, and do not loop forever
ctl "${ids[1]}" denied 45932 start
check "denied: ends up failed (start limit)" poll_until 40 is_failed "${ids[1]}" 45932
check "denied: reason says Permission denied" reason_has "${ids[1]}" 45932 "Permission denied"
ctl "${ids[2]}" hostkey 45933 start
poll_until 40 is_failed "${ids[2]}" 45933
check "hostkey: reason says Host key verification" reason_has "${ids[2]}" 45933 "Host key verification"
ctl "${ids[3]}" resolve 45934 start
poll_until 40 is_failed "${ids[3]}" 45934
check "resolve: reason says Could not resolve" reason_has "${ids[3]}" 45934 "Could not resolve"
ctl "${ids[1]}" ok 45932 start
check "a failed tunnel can be started again" poll_until 20 is_running_and_listening "${ids[1]}" 45932

# 3. a port taken by something else shows up as listening while the unit is inactive
python3 -c "
import socket, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 45935)); s.listen(1); time.sleep(60)" &
FOREIGN_PID=$!
sleep 1
check "foreign listener: unit inactive" test "$(col "${ids[4]}" 45935 3)" = inactive
check "foreign listener: port listening" test "$(col "${ids[4]}" 45935 7)" = 1
check "never-started tunnel reports dead" test "$(col "${ids[4]}" 45935 4)" = dead

# 4. ssh-agent discovery: the unit gets the agent socket even when the shell has no SSH_AUTH_SOCK
agent_tmp=$(mktemp -d)
make_socket() { python3 -c "import socket, sys; s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" "$1"; }
agent_seen() { cat "$XDG_RUNTIME_DIR/conduit-e2e-agent-$1" 2>/dev/null; }
wait_for_file() { [[ -f "$XDG_RUNTIME_DIR/conduit-e2e-agent-$1" ]]; }
start_with_agent() { # start_with_agent port  (reads SSH_AUTH_SOCK / CONDUIT_AGENT_DIR from the caller)
  rm -f "$XDG_RUNTIME_DIR/conduit-e2e-agent-$1"
  ctl "${ids[0]}" ok "$1" restart
  poll_until 20 wait_for_file "$1"
}
make_socket "$agent_tmp/ssh-agent.socket"
unset SSH_AUTH_SOCK
CONDUIT_AGENT_DIR=$agent_tmp start_with_agent 45931
check "agent found in the runtime dir when SSH_AUTH_SOCK is unset" test "$(agent_seen 45931)" = "$agent_tmp/ssh-agent.socket"
make_socket "$agent_tmp/explicit.sock"
SSH_AUTH_SOCK=$agent_tmp/explicit.sock CONDUIT_AGENT_DIR=$agent_tmp start_with_agent 45931
check "an explicit SSH_AUTH_SOCK wins" test "$(agent_seen 45931)" = "$agent_tmp/explicit.sock"
rm -f "$agent_tmp/ssh-agent.socket"
SSH_AUTH_SOCK=$agent_tmp/stale.sock CONDUIT_AGENT_DIR=$agent_tmp start_with_agent 45931
check "a stale SSH_AUTH_SOCK is not passed on" test "$(agent_seen 45931)" != "$agent_tmp/stale.sock"
ctl "${ids[0]}" ok 45931 stop
rm -rf "$agent_tmp" "$XDG_RUNTIME_DIR"/conduit-e2e-agent-*

# 5. "Ask for password": the dialog helper is wired in and nothing restarts by itself
unit_prop() { systemctl --user show "conduit-tunnel-$1.service" -p "$2" --value; } # unit_prop id Property
check "normal tunnel: restarts on failure" bash -c "ASKPASS= TID=${ids[0]} TARGET=ok LP=45931 RH=db.example RP=5432 bash scripts/tunnel-ctl.sh start && [[ \$(systemctl --user show conduit-tunnel-${ids[0]}.service -p Restart --value) == on-failure ]]"
ctl "${ids[0]}" ok 45931 stop
ASKPASS=1 ctl "${ids[5]}" ok 45936 start
check "askpass: tunnel comes up" poll_until 20 is_listening "${ids[5]}" 45936
check "askpass: unit is not restarted by systemd" test "$(unit_prop "${ids[5]}" Restart)" = no
check "askpass: ssh is pointed at askpass.sh" bash -c "systemctl --user show conduit-tunnel-${ids[5]}.service -p Environment --value | grep -q 'SSH_ASKPASS=$PWD/scripts/askpass.sh'"
check "askpass: SSH_ASKPASS_REQUIRE=force" bash -c "systemctl --user show conduit-tunnel-${ids[5]}.service -p Environment --value | grep -q 'SSH_ASKPASS_REQUIRE=force'"
check "askpass: BatchMode is off" bash -c "systemctl --user show conduit-tunnel-${ids[5]}.service -p ExecStart --value | grep -q 'BatchMode=no'"
check "askpass: one password attempt only" bash -c "systemctl --user show conduit-tunnel-${ids[5]}.service -p ExecStart --value | grep -q 'NumberOfPasswordPrompts=1'"
check "askpass: still bound to 127.0.0.1 only" test "$(ss -H -ltn 'sport = :45936' | awk '{print $4}')" = 127.0.0.1:45936
ASKPASS=1 ctl "${ids[5]}" ok 45936 stop
check "askpass: stop works" poll_until 10 is_stopped "${ids[5]}" 45936
# a failing password tunnel stays failed: no retry loop, so no dialog loop
ASKPASS=1 ctl "${ids[6]}" denied 45937 start
check "askpass+denied: ends up failed" poll_until 20 is_failed "${ids[6]}" 45937
sleep 3
check "askpass+denied: systemd never restarted it" test "$(unit_prop "${ids[6]}" NRestarts)" = 0
check "askpass: ASKPASS=0 means a normal tunnel" bash -c "ASKPASS=0 TID=${ids[5]} TARGET=ok LP=45936 RH=db.example RP=5432 bash scripts/tunnel-ctl.sh restart && [[ \$(systemctl --user show conduit-tunnel-${ids[5]}.service -p Restart --value) == on-failure ]]"
ctl "${ids[5]}" ok 45936 stop

# 7. "start" on a running tunnel must not cut it; "restart" does
ctl "${ids[0]}" ok 45931 restart
poll_until 20 is_running_and_listening "${ids[0]}" 45931
pid_of() { systemctl --user show "conduit-tunnel-${ids[0]}.service" -p MainPID --value; }
before=$(pid_of)
check "start on a running tunnel says so" test "$(ctl "${ids[0]}" ok 45931 start)" = "already running"
check "start on a running tunnel keeps the same process" test "$(pid_of)" = "$before"
ctl "${ids[0]}" ok 45931 restart
poll_until 20 is_running_and_listening "${ids[0]}" 45931
check "restart replaces the process" test "$(pid_of)" != "$before"
ctl "${ids[0]}" ok 45931 stop

# 8. ports with a leading zero are refused by the script, as the form refuses them
check "leading-zero local port is refused" bash -c "! TID=${ids[0]} TARGET=ok LP=09 RH=db.example RP=5432 bash scripts/tunnel-ctl.sh start 2>/dev/null"
check "leading-zero remote port is refused" bash -c "! TID=${ids[0]} TARGET=ok LP=45931 RH=db.example RP=0005432x bash scripts/tunnel-ctl.sh start 2>/dev/null"
check "a host that starts with a dash after @ is refused" bash -c "! TID=${ids[0]} TARGET=me@-host LP=45931 RH=db.example RP=5432 bash scripts/tunnel-ctl.sh start 2>/dev/null"
check "no unit was created by the refused starts" test "$(systemctl --user is-active "conduit-tunnel-${ids[0]}.service" 2>/dev/null)" != active

# 9. an error from an earlier run is not shown for the next run
ctl "${ids[7]:-a1b2c308}" denied 45938 start
poll_until 30 reason_has "${ids[7]:-a1b2c308}" 45938 "Permission denied" || true
check "the first run shows its error" reason_has "${ids[7]:-a1b2c308}" 45938 "Permission denied"
ctl "${ids[7]:-a1b2c308}" slow 45938 start
sleep 1
check "a new run does not show the old error while it connects" test -z "$(col "${ids[7]:-a1b2c308}" 45938 8)"
ctl "${ids[7]:-a1b2c308}" slow 45938 stop

# 6. the status script ends with a network line (used to hold back "start automatically")
check "status script ends with an N line" test "$(SPECS='' bash scripts/tunnel-status.sh | tail -1 | cut -f1)" = N
check "N line is 0 or 1" test "$(SPECS='' bash scripts/tunnel-status.sh | tail -1 | cut -f2)" -le 1

echo
echo "$pass passed, $fail failed"
exit $(( fail > 0 ))
