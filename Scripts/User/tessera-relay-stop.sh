#!/usr/bin/env bash
# Stop the local tessera relay.
set -u

PIDS="$(pgrep -f 'debug/tessera run' || true)"
if [ -z "$PIDS" ]; then
  echo "tessera relay: not running."
  exit 0
fi

echo "tessera relay: stopping pid(s) $PIDS"
kill $PIDS 2>/dev/null
sleep 1

LEFT="$(pgrep -f 'debug/tessera run' || true)"
if [ -n "$LEFT" ]; then
  echo "tessera relay: force-killing pid(s) $LEFT"
  kill -9 $LEFT 2>/dev/null
fi
echo "tessera relay: stopped."
