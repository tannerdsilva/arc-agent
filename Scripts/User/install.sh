#!/usr/bin/env bash
# ⚡ ARC Agent installer (hermes-agent-style bootstrap)
#
#   curl -fsSL https://raw.githubusercontent.com/tannerdsilva/arc-agent/master/install.sh | bash
#
# Two acquisition modes, tried in this order:
#   1. download — fetch a prebuilt release tarball from GitHub Releases
#      (fast; no compiler needed). Published by .github/workflows/release.yml.
#   2. source   — clone the repository (+ the sibling `tessera` package) and
#      `swift build -c release`, then install the binaries. Requires a Swift
#      toolchain and access to the tessera repository.
#
# Configuration is deliberately NOT written by the installer: `arc setup`
# (interactive) or `arc doctor` are the first-run steps, mirroring the
# reference agent's install-then-setup flow.
#
# Flags: --manifest --stage NAME --non-interactive --skip-config
#        --dir DIR --bin-dir DIR --branch BRANCH --repo-url URL
#        --tessera-url URL --tessera-branch BRANCH --tessera-path DIR
#        --arch ARCH --source --download --uninstall --verbose --version
# Env:  ARC_REPO_URL ARC_BRANCH ARC_TESSERA_URL ARC_TESSERA_BRANCH
#       ARC_TESSERA_PATH ARC_INSTALL_DIR ARC_BIN_DIR ARC_DOWNLOAD_BASE
set -u

REPO_URL="${ARC_REPO_URL:-https://github.com/tannerdsilva/arc-agent.git}"
BRANCH="${ARC_BRANCH:-master}"
TESSERA_URL="${ARC_TESSERA_URL:-https://github.com/Escalante-Inc/tessera.git}"
TESSERA_BRANCH="${ARC_TESSERA_BRANCH:-dev}"
TESSERA_PATH="${ARC_TESSERA_PATH:-}"
INSTALL_DIR="${ARC_INSTALL_DIR:-$HOME/.arc-agent}"
BIN_DIR="${ARC_BIN_DIR:-$HOME/.local/bin}"
DOWNLOAD_BASE="${ARC_DOWNLOAD_BASE:-https://github.com/tannerdsilva/arc-agent/releases/latest/download}"
ARCH="${ARC_ARCH:-$(uname -m)}"

FORCE_SOURCE=false
FORCE_DOWNLOAD=false
NON_INTERACTIVE=false
SKIP_CONFIG=false
VERBOSE=false
WANT_MANIFEST=false
WANT_VERSION=false
DO_UNINSTALL=false
STAGE=""

log()   { printf '%s\n' "$*"; }
warn()  { printf '  ! %s\n' "$*" >&2; }
die()   { printf 'error: %s\n' "$*" >&2; exit 1; }
cmd()   { if [ "$VERBOSE" = true ]; then log "      $*"; fi; "$@"; }
step()  { log "  → $*"; }

os_name() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux)  echo "linux" ;;
    *)      echo "unknown" ;;
  esac
}

arch_name() {
  case "$ARCH" in
    arm64|aarch64) echo "arm64" ;;
    x86_64|amd64)  echo "x86_64" ;;
    *)             echo "$ARCH" ;;
  esac
}

stages_json() {
  cat <<'EOF'
[
  {"name": "acquire", "desc": "Fetch prebuilt binaries (or source checkouts)"},
  {"name": "build",   "desc": "Compile release binaries from source (source mode)"},
  {"name": "install", "desc": "Place binaries into the bin directory"},
  {"name": "finish",  "desc": "Print next steps (setup/doctor) and PATH hint"}
]
EOF
}

usage() {
  cat <<'EOF'
ARC Agent installer

Usage:
  curl -fsSL https://raw.githubusercontent.com/tannerdsilva/arc-agent/master/install.sh | bash
  bash install.sh --source --non-interactive

Options:
  --dir DIR            install checkout under DIR (default ~/.arc-agent)
  --bin-dir DIR        copy binaries into DIR (default ~/.local/bin)
  --branch BRANCH      arc-agent branch to build (default master)
  --repo-url URL       arc-agent git URL (default tannerdsilva/arc-agent)
  --tessera-url URL    tessera git URL (used in source mode)
  --tessera-branch BR  tessera branch (default dev)
  --tessera-path DIR   use an existing local tessera checkout (no clone)
  --arch ARCH          target architecture for downloads (default: uname -m)
  --source             build from source (skip prebuilt download)
  --download           download prebuilt binaries only (fail if unavailable)
  --manifest           print the stage list as JSON and exit
  --stage NAME         run a single stage and exit
  --non-interactive    never prompt (safe for curl | bash pipelines)
  --skip-config        do not touch configuration at all (default)
  --uninstall          remove installed binaries and the checkout
  --verbose            stream everything
  --version            print the installer version and exit
  -h, --help           this message

Environment overrides: ARC_REPO_URL, ARC_BRANCH, ARC_TESSERA_URL,
ARC_TESSERA_BRANCH, ARC_TESSERA_PATH, ARC_INSTALL_DIR, ARC_BIN_DIR,
ARC_DOWNLOAD_BASE, ARC_ARCH.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)            INSTALL_DIR="$2"; shift 2 ;;
    --bin-dir)        BIN_DIR="$2"; shift 2 ;;
    --branch)         BRANCH="$2"; shift 2 ;;
    --repo-url)       REPO_URL="$2"; shift 2 ;;
    --tessera-url)    TESSERA_URL="$2"; shift 2 ;;
    --tessera-branch) TESSERA_BRANCH="$2"; shift 2 ;;
    --tessera-path)   TESSERA_PATH="$2"; shift 2 ;;
    --arch)           ARCH="$2"; shift 2 ;;
    --source)         FORCE_SOURCE=true; shift ;;
    --download)       FORCE_DOWNLOAD=true; shift ;;
    --non-interactive) NON_INTERACTIVE=true; shift ;;
    --skip-config)    SKIP_CONFIG=true; shift ;;
    --uninstall)      DO_UNINSTALL=true; shift ;;
    --manifest)       WANT_MANIFEST=true; shift ;;
    --stage)          STAGE="$2"; shift 2 ;;
    --verbose)        VERBOSE=true; shift ;;
    --version)        WANT_VERSION=true; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[ "$WANT_VERSION" = true ] && { echo "arc-agent-installer 1.0.0"; exit 0; }
[ "$WANT_MANIFEST" = true ] && { stages_json; exit 0; }

OS="$(os_name)"
ARCH_N="$(arch_name)"
SOURCE_DIR="$INSTALL_DIR/arc-agent"

require() {
  command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

stage_acquire() {
  if [ "$FORCE_SOURCE" = true ]; then
    log "Acquiring source (arc-agent@$BRANCH)…"
    require git
    mkdir -p "$INSTALL_DIR"
    if [ -d "$SOURCE_DIR/.git" ]; then
      step "Updating existing checkout at $SOURCE_DIR"
      cmd git -C "$SOURCE_DIR" fetch --depth 1 origin "$BRANCH"
      cmd git -C "$SOURCE_DIR" checkout --force "$BRANCH"
    else
      step "Cloning arc-agent ($BRANCH) into $SOURCE_DIR"
      cmd git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$SOURCE_DIR" \
        || die "clone failed (is the repository reachable?)"
    fi
    # tessera is a path dependency (../tessera in Package.swift): it must sit
    # beside the arc-agent checkout.
    local tess=$INSTALL_DIR/tessera
    if [ -n "$TESSERA_PATH" ]; then
      step "Linking existing tessera checkout: $TESSERA_PATH"
      if [ ! -d "$tess" ]; then
        cmd ln -s "$TESSERA_PATH" "$tess" \
          || die "could not link $TESSERA_PATH -> $tess"
      fi
    elif [ -d "$tess/.git" ]; then
      step "Updating existing tessera checkout at $tess"
      cmd git -C "$tess" fetch --depth 1 origin "$TESSERA_BRANCH"
      cmd git -C "$tess" checkout --force "$TESSERA_BRANCH"
    else
      step "Cloning tessera ($TESSERA_BRANCH) into $tess"
      cmd git clone --depth 1 --branch "$TESSERA_BRANCH" "$TESSERA_URL" "$tess" \
        || warn "tessera clone failed — source build needs access to that repository"
    fi
    return 0
  fi

  # Default: download a prebuilt release tarball.
  log "Acquiring prebuilt binaries (${OS}-${ARCH_N})…"
  require curl
  require tar
  local name="arc-agent-latest-${OS}-${ARCH_N}.tar.gz"
  local url="$DOWNLOAD_BASE/$name"
  local tmp
  tmp="$(mktemp -d)" || die "mktemp failed"
  step "Downloading $url"
  if cmd curl -fsSL --retry 2 -o "$tmp/$name" "$url"; then
    step "Extracting into $BIN_DIR"
    mkdir -p "$BIN_DIR"
    cmd tar -xzf "$tmp/$name" -C "$BIN_DIR"
    rm -rf "$tmp"
    return 0
  fi
  rm -rf "$tmp"
  if [ "$FORCE_DOWNLOAD" = true ]; then
    die "prebuilt binaries for ${OS}-${ARCH_N} not published yet (no release asset $name)"
  fi
  warn "No prebuilt release asset for ${OS}-${ARCH_N}; falling back to source build."
  if command -v swift >/dev/null 2>&1; then
    FORCE_SOURCE=true
    stage_acquire
  else
    die "no prebuilt asset and no Swift toolchain — install Xcode or publish a release asset"
  fi
}

stage_build() {
  [ -d "$SOURCE_DIR/.git" ] || die "source checkout missing — run the acquire stage first"
  require swift
  log "Building release binaries (this can take a while)…"
  ( cd "$SOURCE_DIR" && cmd swift build -c release )
  [ -f "$SOURCE_DIR/.build/release/arc" ] || [ -f "$SOURCE_DIR/.build/release/arc-agent" ] \
    || die "release build did not produce the arc binary"
}

stage_install() {
  mkdir -p "$BIN_DIR"
  # Copy CLI as `arc` regardless of the target's name, plus the web UI.
  local cli_src=""
  if [ -f "$SOURCE_DIR/.build/release/arc" ]; then cli_src="$SOURCE_DIR/.build/release/arc"
  elif [ -f "$SOURCE_DIR/.build/release/arc-agent" ]; then cli_src="$SOURCE_DIR/.build/release/arc-agent"
  else
    local dl="$BIN_DIR/arc"
    [ -f "$dl" ] || die "no arc binary to install"
  fi
  if [ -n "$cli_src" ]; then
    step "Installing arc → $BIN_DIR/arc"
    cmd install -m 0755 "$cli_src" "$BIN_DIR/arc"
  fi
  if [ -f "$SOURCE_DIR/.build/release/arc-agent-webui" ]; then
    step "Installing arc-agent-webui → $BIN_DIR/arc-agent-webui"
    cmd install -m 0755 "$SOURCE_DIR/.build/release/arc-agent-webui" "$BIN_DIR/arc-agent-webui"
  fi
  step "Installed into $BIN_DIR"
}

stage_finish() {
  [ -x "$BIN_DIR/arc" ] || step "(binaries not present yet; run the install stage)"
  log ""
  log "⚡ ARC Agent is installed"
  log ""
  log "  arc              → $BIN_DIR/arc"
  log "  arc-agent-webui  → $BIN_DIR/arc-agent-webui"
  log ""
  log "You may need to add the bin directory to your PATH:"
  log "  export PATH=\"$BIN_DIR:\$PATH\""
  log ""
  log "Next steps:"
  log "  arc setup    — choose provider, model, approval mode (writes ~/.arc/config.json)"
  log "  arc doctor   — verify the installation and connectivity"
  log "  arc chat -q \"hello world\""
  log ""
  log "Uninstall:  bash install.sh --uninstall  (or remove $BIN_DIR/arc)"
}

stage_uninstall() {
  rm -f "$BIN_DIR/arc" "$BIN_DIR/arc-agent-webui"
  if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
  fi
  log "Removed $BIN_DIR/arc, $BIN_DIR/arc-agent-webui${SKIP_CONFIG:+ (config untouched)}"
  log "~/.arc/config.json (if any) was left in place."
}

if [ "$DO_UNINSTALL" = true ]; then stage_uninstall; exit 0; fi

if [ -n "$STAGE" ]; then
  case "$STAGE" in
    acquire) stage_acquire ;;
    build) stage_build ;;
    install) stage_install ;;
    finish) stage_finish ;;
    *) die "unknown stage: $STAGE (see --manifest)" ;;
  esac
  exit 0
fi

log "⚡ ARC Agent installer (macos|$ARCH_N)"
stage_acquire
stage_build
stage_install
stage_finish
