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
registers the agent as a peer, persists the relay private key, and merges the
`tessera` block into `~/.arc/config.json` (preserving existing model / provider /
security settings):

```bash
Scripts/User/tessera-setup.sh
```

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
