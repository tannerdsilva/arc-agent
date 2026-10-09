#!/usr/bin/env bash
# Start the local arc-agent daemon (`arc serve`) in the background.
#
# Override paths via env vars: ARC_DIR, ARC_BIN, ARC_LOG.
set -u

ARC_DIR="${ARC_DIR:-$HOME/Documents/SwiftProjects/arc-agent}"
ARC_BIN="${ARC_BIN:-$ARC_DIR/.build/debug/arc}"
ARC_LOG="${ARC_LOG:-/private/tmp/arc-serve.log}"

if [ ! -x "$ARC_BIN" ]; then
  echo "error: arc binary not found/executable: $ARC_BIN" >&2
  echo "       build it first: (cd $ARC_DIR && swift build)" >&2
  exit 1
fi

if pgrep -f 'debug/arc serve' >/dev/null 2>&1; then
  echo "arc-agent: already running."
  exit 0
fi

echo "arc-agent: starting ($ARC_BIN serve) …"
nohup "$ARC_BIN" serve > "$ARC_LOG" 2>&1 &
disown

sleep 1
if pgrep -f 'debug/arc serve' >/dev/null 2>&1; then
  echo "arc-agent: started. (log: $ARC_LOG)"
else
  echo "arc-agent: FAILED to start — see $ARC_LOG" >&2
  exit 1
fi
