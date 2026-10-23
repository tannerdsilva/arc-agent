# Installing ARC Agent with Local Tessera Storage

This document describes installing and running ARC Agent against a **local tessera
relay** for storage. It assumes ARC Agent imports `tessera` as a **versioned
SwiftPM dependency** (rather than a sibling path checkout), so only the ARC Agent
repository is cloned for the build; SwiftPM fetches `tessera` automatically.

Both macOS and Linux are covered. The only platform-specific step is installing
the Swift 6.4 toolchain.

## Structure note

ARC Agent links the `tessera-client` **library** product. The tessera **relay
server** is a separate executable (`tessera`) product in the same package, so the
ARC Agent build does **not** produce the relay binary. Local tessera storage
therefore requires building that relay executable from the versioned tessera
source (which SwiftPM already fetches) or installing a published `tessera`
release binary.

## Prerequisites

- Git, curl, tar
- Swift 6.4
  - macOS: `xcode-select --install`
  - Linux: install the Swift 6.4 toolchain from swift.org plus
    `build-essential`

## Install the ARC Agent binary

Clone the repository and build the release binary. SwiftPM fetches the pinned
`tessera` version and links `tessera-client` automatically; no sibling checkout
is required.

```bash
git clone https://github.com/tannerdsilva/arc-agent.git
cd arc-agent
swift build -c release
install -m 0755 .build/release/arc ~/.local/bin/arc
export PATH="$HOME/.local/bin:$PATH"
```

## Build the local tessera relay binary

The versioned tessera source is checked out by SwiftPM under
`.build/checkouts/tessera`. Build the relay executable from there, or use a
published `tessera` release binary if available (and skip this step). The relay
product has heavier dependencies (wireguard, rawdog, bedrock), so this is the
slowest build.

```bash
cd arc-agent/.build/checkouts/tessera
swift build -c release
install -m 0755 .build/release/tessera ~/.local/bin/tessera
```

## Configure the agent

`arc setup` is interactive and writes `~/.arc/config.json` for the model and
provider. It does not configure the tessera connection.

```bash
arc setup
export ARC_API_KEY=***        # or add it to ~/.arc/.env
```

## Wire up the local relay

One command generates the ARC Agent client and relay WireGuard keypairs,
registers the agent as a peer, **registers the agent's identity as a user on
the relay database**, persists the relay private key, and merges the `tessera`
block into `~/.arc/config.json` (preserving existing model / provider /
security settings):

```bash
Scripts/User/tessera-setup.sh
```

The user registration matters as much as the peer registration: the relay must
know the agent's user — the ed25519 identity derived from the agent's private
key (via `tessera create-unbounded-admin`) — or it rejects every event the
agent writes and `arc doctor` fails its health check. The WireGuard peer entry
alone authorizes the transport, not the writer. The step runs while the relay
is stopped (it holds the LMDB write lock), which on a fresh install is the
natural order; if the relay is already running, the script warns and skips —
stop the relay, re-run the script, then start the relay again.

## Start the relay and the agent

```bash
Scripts/User/tessera-relay-start.sh
Scripts/User/arc-agent-start.sh
```

## Verify and use

```bash
arc doctor
arc chat -q "hello world"
```

Stop or restart with the matching `*-stop.sh` / `*-restart.sh` scripts.

### Troubleshooting: `arc doctor` fails the storage health check

If the tunnel comes up but the health check fails with the relay rejecting
writes, the agent's **user is not registered on the relay database** — the
most common cause is a relay DB that predates the user-registration step in
`tessera-setup.sh`. Register it directly (relay stopped):

```bash
set -a; . ~/.arc/.env; set +a
~/.local/bin/tessera create-unbounded-admin \
  --database-path ~/.arc/tessera/db \
  "$ARC_TESSERA_PRIVATE_KEY" ArcAgent
```

Then start the relay and run `arc doctor` again. A second ARC Agent instance
(`ARC_HOME=~/.arc-agent2` or similar) has its own private key and needs its
own registration on the shared relay DB.

## Comparison with the local-path (sibling checkout) model

| Aspect | Local path dependency | Versioned dependency |
| --- | --- | --- |
| Clone ARC Agent only | No — sibling `../tessera` required | Yes — SwiftPM fetches tessera |
| ARC Agent build | Requires `../tessera` present | Self-contained |
| Obtain `tessera` relay binary | Build the sibling repo | Build from `.build/checkouts/tessera`, or a release binary |
| Configuration, relay wiring, start steps | Unchanged | Unchanged |

The only difference is in the install and relay-binary steps: no sibling clone,
and the relay binary is built from the already-fetched tessera checkout (or a
published artifact) rather than a separately cloned repository.
