# ⚡ ARC Agent Makefile
# ────────────────────────────────────────────────────────────
#   make          — debug build
#   make release  — optimized release build
#   make assets   — regenerate KaTeX assets (Gen/katex_assets.py)
#   make install  — release + copy binaries to ~/.local/bin
#   make update   — assets + release + install (full cycle)
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

GEN_KATEX := Scripts/gen_katex_assets.py
KATEX_OUT := Sources/ArcAgentWebUI/Generated/KaTeXAssets.swift

VERSION    := $(shell git describe --tags --always 2>/dev/null || echo "dev")
DIST_DIR   := dist
DIST_NAME  := arc-agent-$(VERSION)-macos-arm64

.PHONY: all build release assets install update dev test clean dist uninstall

# ── Default: debug build ──────────────────────────────────
all: build

build:
	$(SWIFT) build

# ── Release build ─────────────────────────────────────────
release:
	$(SWIFT) build -c release

# ── Regenerate KaTeX assets (embedded Swift strings) ──────
assets:
	@echo "  Regenerating KaTeX assets..."
	python3 $(GEN_KATEX)
	@echo "  → $(KATEX_OUT)"

# ── Install: build release and copy binaries ──────────────
install: release
	@mkdir -p $(INSTALL_DIR)
	cp -f $(BUILD_DIR)/release/$(BINARY) $(INSTALL_DIR)/$(BINARY)
	cp -f $(BUILD_DIR)/release/$(WEBUI) $(INSTALL_DIR)/$(WEBUI)
	@echo "  Installed $(BINARY) + $(WEBUI) → $(INSTALL_DIR)"

# ── Update: full cycle — assets, release, install ─────────
update: assets release install
	@echo "  ✅ Update complete: $(BINARY) v$(VERSION)"

# ── Dev: build debug and run the web UI ───────────────────
dev: build
	@echo "  Starting web UI (http://127.0.0.1:8890)..."
	$(BUILD_DIR)/debug/$(WEBUI)

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
