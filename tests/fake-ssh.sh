#!/usr/bin/env bash
# A stand-in for ssh in the end-to-end test. The "server" name picks the behaviour.
while [ $# -gt 0 ]; do
  case "$1" in -L) fwd=$2; shift 2 ;; --) target=$2; shift 2 ;; *) shift ;; esac
done
lp=$(cut -d: -f2 <<<"$fwd")
# Record the agent socket this process was given, for the agent-discovery test.
if [[ -n ${XDG_RUNTIME_DIR:-} ]]; then echo "${SSH_AUTH_SOCK-unset}" > "$XDG_RUNTIME_DIR/conduit-e2e-agent-$lp"; fi
# "slow" connects after a delay: for checking what the status shows while it is still connecting.
if [[ $target == slow ]]; then sleep 8; fi
case "$target" in
  denied)  echo "$target: Permission denied (publickey)." >&2; exit 255 ;;
  hostkey) echo "Host key verification failed." >&2; exit 255 ;;
  resolve) echo "ssh: Could not resolve hostname $target: Name or service not known" >&2; exit 255 ;;
  *) exec python3 -c "
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', int(sys.argv[1]))); s.listen(5); time.sleep(10**6)" "$lp" ;;
esac
