# ⚡ ARC Agent Makefile
# ────────────────────────────────────────────────────────────
#   make          — debug build
#   make release  — optimized release build
#   make install  — release + copy binaries to ~/.local/bin
#   make update   — release + install (full cycle)
#
# Generated assets are not a make step: ArcAssetPlugin regenerates the theme
# sheet on every build from Sources/ArcTheme/.
#   make dev      — debug build + web UI
#   make test     — run tests
#   make clean    — clean build artifacts
#   make dist     — create a release tarball
#   make uninstall — remove from install dir

SWIFT      := swift
BINARY     := arc
WEBUI      := arc-agent-webui
BUILD_DIR  := .build

INSTALL_DIR ?= $(HOME)/.local/bin

VERSION    := $(shell git describe --tags --always 2>/dev/null || echo "dev")
DIST_DIR   := dist
DIST_NAME  := arc-agent-$(VERSION)-macos-arm64

.PHONY: all build release install update dev test clean dist uninstall

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
	cp -f $(BUILD_DIR)/release/$(BINARY) $(INSTALL_DIR)/$(BINARY)
	cp -f $(BUILD_DIR)/release/$(WEBUI) $(INSTALL_DIR)/$(WEBUI)
	@echo "  Installed $(BINARY) + $(WEBUI) → $(INSTALL_DIR)"

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

# ── Clean ─────────────────────────────────────────────────
clean:
	$(SWIFT) package clean

# ── Distribution tarball ──────────────────────────────────
dist: release
	@mkdir -p $(DIST_DIR)/$(DIST_NAME)
	cp -f $(BUILD_DIR)/release/$(BINARY) $(DIST_DIR)/$(DIST_NAME)/$(BINARY)
	cp -f $(BUILD_DIR)/release/$(WEBUI) $(DIST_DIR)/$(DIST_NAME)/$(WEBUI)
	cp -f README.md $(DIST_DIR)/$(DIST_NAME)/ 2>/dev/null; true
	cp -f LICENSE $(DIST_DIR)/$(DIST_NAME)/ 2>/dev/null; true
	cd $(DIST_DIR) && tar czf $(DIST_NAME).tar.gz $(DIST_NAME)
	rm -rf $(DIST_DIR)/$(DIST_NAME)
	@echo "  → $(DIST_DIR)/$(DIST_NAME).tar.gz"

# ── Uninstall ─────────────────────────────────────────────
uninstall:
	rm -f $(INSTALL_DIR)/$(BINARY)
	rm -f $(INSTALL_DIR)/$(WEBUI)
	@echo "  Removed $(INSTALL_DIR)/$(BINARY), $(INSTALL_DIR)/$(WEBUI)"
