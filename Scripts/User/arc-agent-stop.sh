#!/usr/bin/env bash
# Stop the local arc-agent daemon (`arc serve`).
set -u

PIDS="$(pgrep -f 'debug/arc serve' || true)"
if [ -z "$PIDS" ]; then
  echo "arc-agent: not running."
  exit 0
fi

echo "arc-agent: stopping pid(s) $PIDS"
kill $PIDS 2>/dev/null
sleep 1

LEFT="$(pgrep -f 'debug/arc serve' || true)"
if [ -n "$LEFT" ]; then
  echo "arc-agent: force-killing pid(s) $LEFT"
  kill -9 $LEFT 2>/dev/null
fi
echo "arc-agent: stopped."
