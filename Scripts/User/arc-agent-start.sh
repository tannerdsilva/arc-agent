#!/usr/bin/env bash
# Start the local arc-agent daemon (`arc serve`) in the background.
#
# Override paths via env vars: ARC_DIR, ARC_BIN, ARC_LOG.
set -u

# Load ~/.arc/.env (the secrets file) so the daemon inherits the API key and
# the tessera WireGuard private key rather than reading them from config.json.
ARC_HOME="${ARC_HOME:-$HOME/.arc}"
if [ -f "$ARC_HOME/.env" ]; then
  set -a
  . "$ARC_HOME/.env"
  set +a
fi

ARC_DIR="${ARC_DIR:-$HOME/Documents/SwiftProjects/arc-agent}"
# Production binary home: ~/.local/bin/arc. ARC_BIN overrides it (point it at
# a dev .build/debug/arc while developing). Falls back to PATH, then the
# repo dev build, so the script works on a fresh install and in a checkout.
ARC_BIN="${ARC_BIN:-$HOME/.local/bin/arc}"
if [ ! -x "$ARC_BIN" ]; then
  if command -v arc >/dev/null 2>&1; then
    ARC_BIN="$(command -v arc)"
  elif [ -x "$ARC_DIR/.build/debug/arc" ]; then
    ARC_BIN="$ARC_DIR/.build/debug/arc"
  fi
fi
ARC_LOG="${ARC_LOG:-${TMPDIR:-/tmp}/arc-serve$( [ "$ARC_HOME" = "$HOME/.arc" ] || printf -- "-%s" "${ARC_HOME##*/}" ).log}"
# Instance pidfile: $ARC_HOME/arc-agent.pid. ARC_HOME scopes one pidfile per
# daemon instance, so multi-instance setups (ARC_HOME=~/.arc-agent2 …) can
# stop/restart a single instance instead of every `arc serve` on the machine.
ARC_PIDFILE="${ARC_PIDFILE:-$ARC_HOME/arc-agent.pid}"
# Optional: override the daemon's swift-log level (trace|debug|info|notice|
# warning|error|critical). Empty => daemon's default (.info). Mirrors the
# relay's RELAY_LOG_LEVEL.
ARC_LOG_LEVEL="${ARC_LOG_LEVEL:-}"

if [ ! -x "$ARC_BIN" ]; then
  echo "error: arc binary not found/executable: $ARC_BIN" >&2
  echo "       build a release binary and install it: (cd $ARC_DIR && swift build -c release && install -m 0755 .build/release/arc ~/.local/bin/arc)" >&2
  echo "       or point ARC_BIN at a dev build:  ARC_BIN=\$ARC_DIR/.build/debug/arc" >&2
  exit 1
fi

if [ -f "$ARC_PIDFILE" ] && kill -0 "$(cat "$ARC_PIDFILE")" 2>/dev/null; then
  echo "arc-agent: already running (pid $(cat "$ARC_PIDFILE"), pidfile $ARC_PIDFILE)."
  exit 0
fi
# NOTE: deliberately no pgrep guard here — `arc serve` processes are
# indistinguishable by command line (ARC_HOME lives in the env), so a global
# pgrep would treat a *sibling instance* as this one. The pidfile above is the
# single source of truth; double-starting the same instance fails loudly on
# the port bind instead.

echo "arc-agent: starting ($ARC_BIN serve${ARC_LOG_LEVEL:+ --log-level $ARC_LOG_LEVEL}) …"
# shellcheck disable=SC2086
nohup "$ARC_BIN" serve${ARC_LOG_LEVEL:+ --log-level "$ARC_LOG_LEVEL"} > "$ARC_LOG" 2>&1 &
disown

sleep 1
if kill -0 "$!" 2>/dev/null; then
  mkdir -p "$ARC_HOME"
  echo "$!" > "$ARC_PIDFILE"
  echo "arc-agent: started (pid $!, pidfile $ARC_PIDFILE). (log: $ARC_LOG)"
else
  echo "arc-agent: FAILED to start — see $ARC_LOG" >&2
  exit 1
fi
