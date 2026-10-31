# ⚡ ARC Agent Makefile
# ────────────────────────────────────────────────────────────
#   make          — debug build
#   make release  — optimized release build
#   make install  — release + copy binaries to ~/.local/bin
#   make update   — release + install (full cycle)
#
# Generated assets are not a make step: ArcAssetPlugin regenerates the theme
# sheet on every build from Sources/ArcTheme/.
#   make dev      — debug build + the daemon (API + web UI)
#   make test     — run tests
#   make clean    — clean build artifacts
#   make dist     — create a release tarball
#   make uninstall — remove from install dir

SWIFT      := swift
# the built executable is `arc-agent` (the target name); it installs as `arc`
BINARY     := arc
BUILT      := arc
BUILD_DIR  := .build

INSTALL_DIR ?= $(HOME)/.local/bin

VERSION    := $(shell git describe --tags --always 2>/dev/null || echo "dev")
DIST_DIR   := dist
DIST_NAME  := arc-agent-$(VERSION)-macos-arm64

.PHONY: all build release install update dev test clean dist uninstall check-pin

# ── Default: debug build ──────────────────────────────────
all: build

build:
	$(SWIFT) build

# ── Release build ─────────────────────────────────────────
release:
	$(SWIFT) build -c release

# ── Install: build release and copy binaries ──────────────
install: release
	@mkdir -p $(INSTALL_DIR)
	cp -f $(BUILD_DIR)/release/$(BUILT) $(INSTALL_DIR)/$(BINARY)
	@echo "  Installed $(BUILT) → $(INSTALL_DIR)/$(BINARY)"

# ── Update: full cycle — assets, release, install ─────────
update: release install
	@echo "  ✅ Update complete: $(BINARY) v$(VERSION)"

# ── Dev: build debug and run the daemon (API + web UI) ────
dev: build
	@echo "  Starting the daemon (web UI http://127.0.0.1:8890, API http://127.0.0.1:8080)..."
	$(SWIFT) run $(BINARY) serve

# ── Test ──────────────────────────────────────────────────
test:
	$(SWIFT) test 2>&1

# ── Dependency pin ────────────────────────────────────────
# no-webui is pinned by ORIGIN URL at a BRANCH (master), so the revision lives in
# Package.resolved and not in the manifest. the check is that resolution is
# current: the resolved revision must equal the checkout's HEAD.

check-pin:
	@entry=$$(grep -A6 '"identity" : "no-webui"' Package.resolved); \
	rev=$$(printf '%s\n' "$$entry" | grep -o '[0-9a-f]\{40\}' | head -1); \
	br=$$(printf '%s\n' "$$entry" | sed -n 's/.*"branch" : "\([^"]*\)".*/\1/p' | head -1); \
	if [ -z "$$rev" ]; then echo "  ✗ Package.resolved records no no-webui revision — run: swift package resolve"; exit 1; fi; \
	have=$$(git -C .build/checkouts/no-webui rev-parse HEAD 2>/dev/null || echo missing); \
	if [ "$$have" = "$$rev" ]; then echo "  no-webui at $${br:-resolved revision} ($$rev)"; \
	elif [ "$$have" = "missing" ]; then echo "  ✗ no no-webui checkout under .build — run: swift package resolve"; exit 1; \
	else echo "  ✗ checkout $$have != resolved $$rev — run: swift package resolve"; exit 1; fi
	@if [ -d ../no-webui ]; then echo "  ℹ sibling at $$(git -C ../no-webui rev-parse --short HEAD) (advisory; the pin is authoritative)"; fi

# ── Clean ─────────────────────────────────────────────────
clean:
	$(SWIFT) package clean

# ── Distribution tarball ──────────────────────────────────
dist: release
	@mkdir -p $(DIST_DIR)/$(DIST_NAME)
	cp -f $(BUILD_DIR)/release/$(BUILT) $(DIST_DIR)/$(DIST_NAME)/$(BINARY)
	cp -f README.md $(DIST_DIR)/$(DIST_NAME)/ 2>/dev/null; true
	cp -f LICENSE $(DIST_DIR)/$(DIST_NAME)/ 2>/dev/null; true
	cd $(DIST_DIR) && tar czf $(DIST_NAME).tar.gz $(DIST_NAME)
	rm -rf $(DIST_DIR)/$(DIST_NAME)
	@echo "  → $(DIST_DIR)/$(DIST_NAME).tar.gz"

# ── Uninstall ─────────────────────────────────────────────
uninstall:
	rm -f $(INSTALL_DIR)/$(BINARY)
	# legacy cleanup: the standalone UI binary, retired in the daemon consolidation
	rm -f $(INSTALL_DIR)/arc-agent-webui
	@echo "  Removed $(INSTALL_DIR)/$(BINARY) (+ legacy arc-agent-webui if present)"
