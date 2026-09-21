# ⚡ ARC Agent Makefile
# ────────────────────────────────────────────────────────────
#   make          — debug build
#   make release  — optimized release build
#   make install  — release + copy to ~/.local/bin
#   make test     — run tests
#   make clean    — clean build artifacts
#   make dist     — create a release tarball
#   make uninstall — remove from install dir

SWIFT      := swift
BINARY     := arc
BUILD_DIR  := .build

INSTALL_DIR ?= $(HOME)/.local/bin

VERSION    := $(shell git describe --tags --always 2>/dev/null || echo "dev")
DIST_DIR   := dist
DIST_NAME  := arc-agent-$(VERSION)-macos-arm64

.PHONY: all build release install test clean dist uninstall wasm-client

# ── Default: debug build ──────────────────────────────────
all: build

build:
	$(SWIFT) build

# ── Client-mode wasm artifact (from the no-webui checkout) ──
# builds the WebUIClient product the /client demo page serves.
# needs the swiftly-hosted swift 6.4 wasm sdk registered; the Xcode
# frontend cannot read the sdk's prebuilt modules, so the swiftly shim
# is used directly. override with NO_WEBUI_DIR=/path/to/no-webui or
# WASM_SWIFT=/path/to/swift.
NO_WEBUI_DIR ?= ../no-webui
WASM_SWIFT ?= $(HOME)/.swiftly/bin/swift
wasm-client:
	cd $(NO_WEBUI_DIR) && $(WASM_SWIFT) build -c release --swift-sdk swift-6.4.0-RELEASE_wasm --product WebUIClient
	@echo "  built WebUIClient.wasm → $(NO_WEBUI_DIR)/.build/out/Products/Release-webassembly-wasm32/"

# ── Release build ─────────────────────────────────────────
release:
	$(SWIFT) build -c release

# ── Install: build release and copy binary ────────────────
install: release
	@mkdir -p $(INSTALL_DIR)
	cp -f $(BUILD_DIR)/release/$(BINARY) $(INSTALL_DIR)/$(BINARY)
	@echo "  Installed $(BINARY) → $(INSTALL_DIR)/$(BINARY)"

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
	cp -f README.md $(DIST_DIR)/$(DIST_NAME)/ 2>/dev/null; true
	cp -f LICENSE $(DIST_DIR)/$(DIST_NAME)/ 2>/dev/null; true
	cd $(DIST_DIR) && tar czf $(DIST_NAME).tar.gz $(DIST_NAME)
	rm -rf $(DIST_DIR)/$(DIST_NAME)
	@echo "  → $(DIST_DIR)/$(DIST_NAME).tar.gz"

# ── Uninstall ─────────────────────────────────────────────
uninstall:
	rm -f $(INSTALL_DIR)/$(BINARY)
	@echo "  Removed $(INSTALL_DIR)/$(BINARY)"
