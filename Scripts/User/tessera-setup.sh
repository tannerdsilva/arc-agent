#!/usr/bin/env bash
# One-shot setup of the local tessera relay <-> arc-agent WireGuard wiring.
#
# What it does:
#   1. Generates a WireGuard keypair for the arc-agent *client* and another for
#      the *relay* (via `tessera generate-keys`).
#   2. Adds the client's public key to the relay's peer config
#      (~/.arc/tessera/cfg/peer-config.json) via `tessera config add`.
#   3. Persists the relay's private key to ~/.arc/tessera/relay.key so
#      `tessera-relay-start.sh` can pick it up automatically.
#   4. Merges the `tessera` block into ~/.arc/config.json so `arc` can reach the
#      local relay. Existing config (model/provider/etc.) is preserved.
#
# Run AFTER `arc setup` (which creates ~/.arc/config.json). Re-running this
# script regenerates the keys and rewires both sides.
#
# Override via env: TESSERA_DIR, TESSERA_BIN, ARC_HOME, ARC_CONFIG,
#                   TESSERA_CFG_DIR, RELAY_PORT, RELAY_IP, RELAY_KEEP_ALIVE,
#                   ARC_APPLICATION
set -u

TESSERA_DIR="${TESSERA_DIR:-$HOME/Documents/SwiftProjects/tessera}"
TESSERA_BIN="${TESSERA_BIN:-$HOME/.local/bin/tessera}"
if [ ! -x "$TESSERA_BIN" ]; then
  if command -v tessera >/dev/null 2>&1; then
    TESSERA_BIN="$(command -v tessera)"
  elif [ -x "$TESSERA_DIR/.build/debug/tessera" ]; then
    TESSERA_BIN="$TESSERA_DIR/.build/debug/tessera"
  fi
fi
if [ ! -x "$TESSERA_BIN" ]; then
  echo "error: tessera binary not found/executable: $TESSERA_BIN" >&2
  echo "       build it first: (cd $TESSERA_DIR && swift build) or install to ~/.local/bin/tessera" >&2
  exit 1
fi

ARC_HOME="${ARC_HOME:-$HOME/.arc}"
ARC_CONFIG="${ARC_CONFIG:-$ARC_HOME/config.json}"
TESSERA_CFG_DIR="${TESSERA_CFG_DIR:-$ARC_HOME/tessera/cfg}"
RELAY_PORT="${RELAY_PORT:-51921}"
RELAY_IP="${RELAY_IP:-127.0.0.1}"
RELAY_KEEP_ALIVE="${RELAY_KEEP_ALIVE:-15}"
ARC_APPLICATION="${ARC_APPLICATION:-1}"

log()  { printf '%s\n' "$*"; }
step() { log "  → $*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# Parse a single `tessera generate-keys` output into pub/priv.
genshot() {
  "$TESSERA_BIN" generate-keys
}
pub_of() { sed -n 's/^Public Key: //p'; }
priv_of() { sed -n 's/^Private Key: //p'; }

command -v python3 >/dev/null 2>&1 || die "python3 is required to merge the tessera block into ~/.arc/config.json"

log "⚡ tessera setup — generating WireGuard keypairs…"

CLIENT_KEYS="$(genshot)" || die "could not generate the client WireGuard keypair"
RELAY_KEYS="$(genshot)" || die "could not generate the relay WireGuard keypair"
CLIENT_PUB="$(printf '%s\n' "$CLIENT_KEYS" | pub_of)"
CLIENT_PRIV="$(printf '%s\n' "$CLIENT_KEYS" | priv_of)"
RELAY_PUB="$(printf '%s\n' "$RELAY_KEYS" | pub_of)"
RELAY_PRIV="$(printf '%s\n' "$RELAY_KEYS" | priv_of)"
[ -n "$CLIENT_PUB" ] || die "failed to read the client public key"
[ -n "$RELAY_PUB" ]  || die "failed to read the relay public key"

step "registering the agent peer with the relay"
mkdir -p "$TESSERA_CFG_DIR"
"$TESSERA_BIN" config add \
  --configuration-path "$TESSERA_CFG_DIR" \
  --ip-address "$RELAY_IP" \
  --port "$RELAY_PORT" \
  --keep-alive "$RELAY_KEEP_ALIVE" \
  --tessera false \
  --overwrite true \
  "$CLIENT_PUB" || die "failed to add the agent peer to the relay config"

step "persisting the relay private key (used by tessera-relay-start.sh)"
mkdir -p "$ARC_HOME/tessera"
printf '%s\n' "$RELAY_PRIV" > "$ARC_HOME/tessera/relay.key"
chmod 600 "$ARC_HOME/tessera/relay.key"

step "merging the tessera block into $ARC_CONFIG"
ARC_CONFIG="$ARC_CONFIG" ARC_APPLICATION="$ARC_APPLICATION" \
RELAY_PORT="$RELAY_PORT" RELAY_IP="$RELAY_IP" \
RELAY_PUB="$RELAY_PUB" CLIENT_PRIV="$CLIENT_PRIV" \
python3 - <<'PY'
import json, os, sys
path = os.environ["ARC_CONFIG"]
cfg = {}
if os.path.exists(path):
    try:
        cfg = json.load(open(path))
    except Exception:
        cfg = {}   # start fresh if the file is malformed
cfg["tessera"] = {
    "application": int(os.environ["ARC_APPLICATION"]),
    "serverPort": int(os.environ["RELAY_PORT"]),
    "serverIP": os.environ["RELAY_IP"],
    "serverPublicKey": os.environ["RELAY_PUB"],
    "myPrivateKey": os.environ["CLIENT_PRIV"],
}
json.dump(cfg, open(path, "w"), indent=2)
print(f"wrote tessera block -> {path}")
PY

log ""
log "⚡ tessera wiring is set up."
log "  relay (client) public key : $CLIENT_PUB"
log "  relay  public key         : $RELAY_PUB"
log ""
log "Next steps:"
log "  Scripts/User/tessera-relay-start.sh   # start the relay"
log "  Scripts/User/arc-agent-start.sh       # start the agent daemon"
log "  arc doctor                            # verify connectivity"
log ""
log "Note: the relay private key was saved to $ARC_HOME/tessera/relay.key"
log "      (chmod 600). Re-running this script regenerates the keys."
