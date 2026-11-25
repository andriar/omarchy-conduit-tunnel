#!/usr/bin/env bash
# Print one tab-separated line per tunnel:
#   T <id> <ActiveState> <SubState> <restarts> <active-since-epoch> <listening 0|1> <last error line>
# SPECS is "id:localport id:localport ...".
# The last line is `N <0|1>`: whether there is a default route (a network at all).
set -u

for spec in ${SPECS:-}; do
  id=${spec%%:*}
  port=${spec##*:}
  [[ $id =~ ^[0-9a-f]{8}$ && $port =~ ^[0-9]+$ ]] || continue
  unit="conduit-tunnel-$id.service"

  props=$(systemctl --user show "$unit" -p ActiveState -p SubState -p NRestarts -p ActiveEnterTimestamp 2>/dev/null)
  active=$(sed -n 's/^ActiveState=//p' <<<"$props")
  sub=$(sed -n 's/^SubState=//p' <<<"$props")
  restarts=$(sed -n 's/^NRestarts=//p' <<<"$props")
  since=$(sed -n 's/^ActiveEnterTimestamp=//p' <<<"$props")
  enter=0
  [[ -n $since ]] && enter=$(date -d "$since" +%s 2>/dev/null || echo 0)

  # ssh only listens on the local port once it is connected and the forward is set up.
  listening=0
  ss -H -ltn "sport = :$port" 2>/dev/null | grep -q . && listening=1

  reason=""
  if [[ $active == failed || $active == activating || ( $active == active && $listening == 0 ) ]]; then
    # Only this run's own log: an error from an earlier run must not outlive a fix.
    inv=$(systemctl --user show "$unit" -p InvocationID --value 2>/dev/null)
    [[ $inv =~ ^[0-9a-f]{32}$ ]] || inv=""
    reason=""
    [[ -n $inv ]] && reason=$(journalctl --user "_SYSTEMD_INVOCATION_ID=$inv" -n 30 --no-pager -o cat 2>/dev/null \
      | grep -E 'Permission denied|Host key verification|IDENTIFICATION HAS CHANGED|Could not resolve|Name or service not known|Connection refused|timed out|No route to host|Network is unreachable|Address already in use|Could not request local forwarding|bind' \
      | tail -1 | tr -d '\r\t' | cut -c1-200)
  fi

  printf 'T\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "${active:-inactive}" "${sub:-dead}" "${restarts:-0}" "$enter" "$listening" "$reason"
done

online=0
ip -o route show default 2>/dev/null | grep -q . && online=1
printf 'N\t%s\n' "$online"
