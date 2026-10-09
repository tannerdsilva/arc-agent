#!/usr/bin/env bash
# Restart (stop, then start) the local arc-agent daemon.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/arc-agent-stop.sh"
sleep 1
"$SCRIPT_DIR/arc-agent-start.sh"
