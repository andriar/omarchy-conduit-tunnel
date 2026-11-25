#!/usr/bin/env bash
# End-to-end test of the shell scripts against real systemd --user units, with a fake ssh.
# Needs a systemd user session. Uses ports 45931-45935 and units conduit-tunnel-a1b2c30*.
#   tests/e2e-local.sh
set -u
cd "$(dirname "$0")/.."
export CONDUIT_SSH_BIN="$PWD/tests/fake-ssh.sh" CONDUIT_RESTART_SEC=1
pass=0; fail=0
ok() { if [[ $2 == 1 ]]; then pass=$((pass+1)); echo "PASS $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }
# Tunnel ids are 8 hex digits.
ids=(a1b2c301 a1b2c302 a1b2c303 a1b2c304 a1b2c305)
ctl() { TID=$1 TARGET=$2 LP=$3 RH=db.example RP=5432 bash scripts/tunnel-ctl.sh "$4"; }
status() { SPECS="$1:$2" bash scripts/tunnel-status.sh; }
field() { cut -f"$2" <<<"$1"; }
cleanup() { for i in "${ids[@]}"; do TID=$i bash scripts/tunnel-ctl.sh stop >/dev/null 2>&1; done; [[ -n ${PID:-} ]] && kill "$PID" 2>/dev/null; }
trap cleanup EXIT
wait_for() { for _ in $(seq 1 "${3:-20}"); do out=$(status "$1" "$2"); eval "$4" && return 0; sleep 0.5; done; return 1; }

# 1. a working tunnel comes up, listens on loopback only, and stops cleanly
ctl "${ids[0]}" ok 45931 start; ok "start ok tunnel returns 0" $([[ $? == 0 ]] && echo 1 || echo 0)
wait_for "${ids[0]}" 45931 20 '[[ $(field "$out" 7) == 1 ]]'; ok "listening after start" $([[ $? == 0 ]] && echo 1 || echo 0)
out=$(status "${ids[0]}" 45931)
ok "unit is active" $([[ $(field "$out" 3) == active ]] && echo 1 || echo 0)
ok "start time recorded" $([[ $(field "$out" 6) -gt 1700000000 ]] && echo 1 || echo 0)
addr=$(ss -H -ltn 'sport = :45931' | awk '{print $4}')
ok "bound to 127.0.0.1 only ($addr)" $([[ $addr == 127.0.0.1:45931 ]] && echo 1 || echo 0)
ctl "${ids[0]}" ok 45931 restart; wait_for "${ids[0]}" 45931 20 '[[ $(field "$out" 7) == 1 ]]'; ok "restart replaces it and it listens again" $([[ $? == 0 ]] && echo 1 || echo 0)
ctl "${ids[0]}" ok 45931 stop
wait_for "${ids[0]}" 45931 10 '[[ $(field "$out" 3) == inactive && $(field "$out" 7) == 0 ]]'; ok "stop: inactive and port released" $([[ $? == 0 ]] && echo 1 || echo 0)

# 2. failures end as 'failed' with a readable reason, and do not loop forever
ctl "${ids[1]}" denied 45932 start
wait_for "${ids[1]}" 45932 40 '[[ $(field "$out" 3) == failed ]]'; ok "denied: ends up failed (start limit)" $([[ $? == 0 ]] && echo 1 || echo 0)
out=$(status "${ids[1]}" 45932); ok "denied: reason mentions Permission denied" $([[ $(field "$out" 8) == *"Permission denied"* ]] && echo 1 || echo 0)
ctl "${ids[2]}" hostkey 45933 start
wait_for "${ids[2]}" 45933 40 '[[ $(field "$out" 3) == failed ]]'; out=$(status "${ids[2]}" 45933)
ok "hostkey: reason mentions Host key verification" $([[ $(field "$out" 8) == *"Host key verification"* ]] && echo 1 || echo 0)
ctl "${ids[3]}" resolve 45934 start
wait_for "${ids[3]}" 45934 40 '[[ $(field "$out" 3) == failed ]]'; out=$(status "${ids[3]}" 45934)
ok "resolve: reason mentions Could not resolve" $([[ $(field "$out" 8) == *"Could not resolve"* ]] && echo 1 || echo 0)
ctl "${ids[1]}" ok 45932 start; wait_for "${ids[1]}" 45932 20 '[[ $(field "$out" 3) == active && $(field "$out" 7) == 1 ]]'
ok "a failed tunnel can be started again" $([[ $? == 0 ]] && echo 1 || echo 0)

# 3. a port taken by something else shows up as listening while the unit is inactive
python3 -c "
import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1',45935)); s.listen(1); time.sleep(60)" &
PID=$!; sleep 1
out=$(status "${ids[4]}" 45935)
ok "foreign listener: unit inactive, port listening" $([[ $(field "$out" 3) == inactive && $(field "$out" 7) == 1 ]] && echo 1 || echo 0)
ok "never-started tunnel reports inactive/dead" $([[ $(field "$out" 4) == dead ]] && echo 1 || echo 0)

echo; echo "$pass passed, $fail failed"; exit $(( fail > 0 ))
