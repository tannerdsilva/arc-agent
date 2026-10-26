#!/usr/bin/env bash
# Stop the local arc-agent daemon (`arc serve`).
#
# Instance selection: the daemon started by arc-agent-start.sh records its pid
# in $ARC_HOME/arc-agent.pid, so setting ARC_HOME stops exactly that instance
# (ARC_HOME=~/.arc-agent2 arc-agent-stop.sh stops only the second instance).
# With no pidfile (daemon launched some other way), fall back to matching all
# `arc serve` processes.
set -u

ARC_HOME="${ARC_HOME:-$HOME/.arc}"
ARC_PIDFILE="${ARC_PIDFILE:-$ARC_HOME/arc-agent.pid}"

stop_pid() {
  local pid="$1"
  kill "$pid" 2>/dev/null
  sleep 1
  if kill -0 "$pid" 2>/dev/null; then
    echo "arc-agent: force-killing pid $pid"
    kill -9 "$pid" 2>/dev/null
  fi
}

if [ -f "$ARC_PIDFILE" ]; then
  PID="$(cat "$ARC_PIDFILE" 2>/dev/null || true)"
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    echo "arc-agent: stopping pid $PID (pidfile $ARC_PIDFILE)"
    stop_pid "$PID"
    rm -f "$ARC_PIDFILE"
    echo "arc-agent: stopped."
  else
    rm -f "$ARC_PIDFILE"
    echo "arc-agent: not running (stale pidfile removed)."
  fi
  exit 0
fi

# No pidfile — legacy fallback: match every `arc serve` on the machine.
PIDS="$(pgrep -f '[a]rc serve' || true)"
if [ -z "$PIDS" ]; then
  echo "arc-agent: not running."
  exit 0
fi

echo "arc-agent: no pidfile; stopping matching pid(s) $PIDS"
for pid in $PIDS; do
  stop_pid "$pid"
done
echo "arc-agent: stopped."
