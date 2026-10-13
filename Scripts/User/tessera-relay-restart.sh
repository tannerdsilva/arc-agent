#!/usr/bin/env bash
# Restart (stop, then start) the local tessera relay.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/tessera-relay-stop.sh"
sleep 1
"$SCRIPT_DIR/tessera-relay-start.sh"
