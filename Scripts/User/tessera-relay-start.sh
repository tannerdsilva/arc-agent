#!/usr/bin/env bash
# Start the local tessera relay in the background.
#
# Override paths/values via env vars: TESSERA_DIR, RELAY_DB, RELAY_CFG,
# RELAY_KEY, RELAY_PORT, RELAY_LOG.
set -u

TESSERA_DIR="${TESSERA_DIR:-$HOME/Documents/SwiftProjects/tessera}"
RELAY_BIN="${RELAY_BIN:-$TESSERA_DIR/.build/debug/tessera}"
RELAY_DB="${RELAY_DB:-$HOME/.arc/tessera/db}"
RELAY_CFG="${RELAY_CFG:-$HOME/.arc/tessera/cfg}"
RELAY_KEY="${RELAY_KEY:-0PKKUSzUpiV7c23b134QmtsBXKD0Os1xG69cRmJp9lw=}"
RELAY_PORT="${RELAY_PORT:-51921}"
RELAY_LOG="${RELAY_LOG:-/private/tmp/relay-federated.log}"

if [ ! -x "$RELAY_BIN" ]; then
  echo "error: relay binary not found/executable: $RELAY_BIN" >&2
  echo "       build it first: (cd $TESSERA_DIR && swift build)" >&2
  exit 1
fi

if pgrep -f 'debug/tessera run' >/dev/null 2>&1; then
  echo "tessera relay: already running."
  exit 0
fi

mkdir -p "$RELAY_DB" "$RELAY_CFG"
echo "tessera relay: starting on port $RELAY_PORT …"
nohup "$RELAY_BIN" run \
  --database-path "$RELAY_DB" \
  --configuration-path "$RELAY_CFG" \
  --sync-interval 30 \
  "$RELAY_PORT" "$RELAY_KEY" > "$RELAY_LOG" 2>&1 &
disown

sleep 1
if pgrep -f 'debug/tessera run' >/dev/null 2>&1; then
  echo "tessera relay: started. (log: $RELAY_LOG)"
else
  echo "tessera relay: FAILED to start — see $RELAY_LOG" >&2
  exit 1
fi
