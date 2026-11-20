#!/usr/bin/env bash
# Stop the local arc-agent daemon (`arc serve`).
#
# Instance selection: the daemon started by arc-agent-start.sh records its pid
# in $ARC_HOME/arc-agent.pid, so setting ARC_HOME stops exactly that instance
# (ARC_HOME=~/.arc-agent2 arc-agent-stop.sh stops only the second instance).
# With no pidfile (daemon launched some other way), fall back to matching all
# `arc serve` processes.
#
# Port orphan sweep: regardless of the pidfile path, any process still
# LISTENING on the daemon's ports is stopped too — but only if its command is
# actually an `arc serve` process. Anything else holding a port (an unrelated
# dev server, another app) is reported and left alone.
set -u

ARC_HOME="${ARC_HOME:-$HOME/.arc}"
ARC_PIDFILE="${ARC_PIDFILE:-$ARC_HOME/arc-agent.pid}"
ARC_HTTP_PORT="${ARC_HTTP_PORT:-8080}"
ARC_WEBUI_PORT="${ARC_WEBUI_PORT:-8890}"

stop_pid() {
  local pid="$1"
  kill "$pid" 2>/dev/null
  sleep 1
  if kill -0 "$pid" 2>/dev/null; then
    echo "arc-agent: force-killing pid $pid"
    kill -9 "$pid" 2>/dev/null
  fi
}

# True if the given pid's command is an arc agent serve process.
is_arc_serve() {
  local pid="$1"
  local cmd
  cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  # The daemon is always launched as `…/arc serve` (installed binary, a
  # .build/…/arc debug binary, or similar). Require the basename to be `arc`
  # with `serve` as its first argument, so e.g. `arch` or `march` never match.
  echo "$cmd" | grep -qE '(^|/)(\./)?arc serve( |$)'
}

# Stop any arc-agent process squatting on the daemon's ports (stale pidfile,
# daemon launched by hand, a crashed instance's leftover, …).
stop_port_orphans() {
  local port pid desc
  for port in "$ARC_HTTP_PORT" "$ARC_WEBUI_PORT"; do
    for pid in $(lsof -nP -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true); do
      [ "$pid" = "$$" ] && continue
      if is_arc_serve "$pid"; then
        echo "arc-agent: stopping port-orphan pid $pid (listening on :$port)"
        stop_pid "$pid"
      else
        desc="$(ps -p "$pid" -o command= 2>/dev/null | cut -c1-80 || true)"
        echo "arc-agent: :$port held by non-arc pid $pid ($desc) — leaving it alone"
      fi
    done
  done
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
  stop_port_orphans
  exit 0
fi

# No pidfile — legacy fallback: match every `arc serve` on the machine.
PIDS="$(pgrep -f '[a]rc serve' || true)"
if [ -z "$PIDS" ]; then
  echo "arc-agent: not running."
  stop_port_orphans
  exit 0
fi

echo "arc-agent: no pidfile; stopping matching pid(s) $PIDS"
for pid in $PIDS; do
  stop_pid "$pid"
done
stop_port_orphans
echo "arc-agent: stopped."
