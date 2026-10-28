#!/usr/bin/env bash
# One-shot setup of the local tessera relay <-> arc-agent WireGuard wiring.
#
# What it does:
#   1. Generates a WireGuard keypair for the arc-agent *client* and another for
#      the *relay* (via `tessera generate-keys`).
#   2. Adds the client's public key to the relay's peer config
#      (~/.arc/tessera/cfg/peer-config.json) via `tessera config add`.
#   3. Registers the agent's identity (ed25519, derived from its private key)
#      as a user on the relay database (~/.arc/tessera/db) via
#      `tessera create-unbounded-admin`. Without this the relay rejects the
#      agent's writes and `arc doctor` fails its health check.
#   4. Persists the relay's private key to ~/.arc/tessera/relay.key so
#      `tessera-relay-start.sh` can pick it up automatically.
#   5. Merges the `tessera` block into ~/.arc/config.json so `arc` can reach the
#      local relay. Existing config (model/provider/etc.) is preserved.
#
# Run AFTER `arc setup` (which creates ~/.arc/config.json). Re-running this
# script regenerates the keys and rewires both sides.
#
# Override via env: TESSERA_DIR, TESSERA_BIN, ARC_HOME, ARC_CONFIG,
#                   TESSERA_CFG_DIR, RELAY_PORT, RELAY_IP, RELAY_KEEP_ALIVE,
#                   ARC_APPLICATION, RELAY_DB, ARC_USER_NAME
#
# RELAY_DB — where the agent user is registered. Defaults to
#            $ARC_HOME/tessera/db (matches tessera-relay-start.sh). When a
#            second instance shares an existing relay, set it to that relay's
#            DB (e.g. RELAY_DB=~/.arc/tessera/db) and its TESSERA_CFG_DIR too.
# ARC_USER_NAME — the user name written to the relay DB (default: ArcAgent).
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
  --keep-alive "$RELAY_KEEP_ALIVE" \
  --tessera false \
  --overwrite true \
  "$CLIENT_PUB" || die "failed to add the agent peer to the relay config"

# The relay's DB must also know the agent's *user* — the ed25519 identity
# derived from the agent's private key — or every event write is rejected and
# `arc doctor` fails its health check. The WireGuard peer registration alone is
# not enough. The relay must be stopped for this step (it holds the LMDB
# write lock); on a fresh install it has not been started yet, which is why
# this runs before the relay-start script.
step "registering the agent identity as a user on the relay database"
if pgrep -f '[t]essera run' >/dev/null 2>&1; then
  log "  warning: the tessera relay is running — stop it first, re-run this"
  log "  script, then start the relay. Skipping user registration."
  RELAY_DB="${RELAY_DB:-$ARC_HOME/tessera/db}"
  RELAY_DB_REGISTERED=false
else
  RELAY_DB="${RELAY_DB:-$ARC_HOME/tessera/db}"
  mkdir -p "$RELAY_DB"
  # Registers a full-access user named ARC_USER_NAME (default: ArcAgent) whose
  # ed25519 signing key is derived from the agent's private key. Re-running
  # with the same key re-scribes the same user event (idempotent).
  if "$TESSERA_BIN" create-unbounded-admin \
      --database-path "$RELAY_DB" \
      "$CLIENT_PRIV" "${ARC_USER_NAME:-ArcAgent}"; then
    RELAY_DB_REGISTERED=true
  else
    log "  warning: user registration failed — the relay DB may be locked or"
    log "  unreadable. arc's health check will fail until this succeeds."
    RELAY_DB_REGISTERED=false
  fi
fi

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
    "myPrivateKey": "",  # the client private key lives in ~/.arc/.env (ARC_TESSERA_PRIVATE_KEY)
}
json.dump(cfg, open(path, "w"), indent=2)
print(f"wrote tessera block -> {path}")
PY

step "persisting the agent(private) key to the secrets file (not config.json)"
ARC_HOME="$ARC_HOME" CLIENT_PRIV="$CLIENT_PRIV" python3 - <<'PY'
import os
env_path = os.path.join(os.environ["ARC_HOME"], ".env")
key = "ARC_TESSERA_PRIVATE_KEY"; val = os.environ["CLIENT_PRIV"]
lines = open(env_path).read().splitlines() if os.path.exists(env_path) else []
out, replaced = [], False
for ln in lines:
    if ln.startswith(key + "="):
        out.append(key + "=" + val); replaced = True
    else:
        out.append(ln)
if not replaced:
    out.append(key + "=" + val)
open(env_path, "w").write("\n".join(out) + "\n")
os.chmod(env_path, 0o600)
print(f"wrote {key} -> {env_path}")
PY
chmod 600 "$ARC_CONFIG" 2>/dev/null || true

log ""
log "⚡ tessera wiring is set up."
log "  relay (client) public key : $CLIENT_PUB"
log "  relay  public key         : $RELAY_PUB"
if [ "${RELAY_DB_REGISTERED:-false}" = true ]; then
  log "  agent user registered     : ${ARC_USER_NAME:-ArcAgent} on $RELAY_DB"
fi
log ""
log "Next steps:"
log "  Scripts/User/tessera-relay-start.sh   # start the relay"
log "  Scripts/User/arc-agent-start.sh       # start the agent daemon"
log "  arc doctor                            # verify connectivity"
log ""
log "Note: the relay private key was saved to $ARC_HOME/tessera/relay.key"
log "      (chmod 600). The agent(private) key is stored in $ARC_HOME/.env"
log "      as ARC_TESSERA_PRIVATE_KEY (chmod 600). Re-running this script"
log "      regenerates the keys and re-registers the agent user."
