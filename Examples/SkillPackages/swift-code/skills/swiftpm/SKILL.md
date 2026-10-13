---
name: swiftpm
description: Use SwiftPM to build, test, and scan a Swift package, matching the repo's utility conventions.
---

# SwiftPM

- Builds use `swift build`; tests use `swift test`. Default Xcode toolchain is Swift 6.4.
- Inspect targets/dependencies before editing `Package.swift`; each new dependency is a maintenance commitment.
- Prefer Foundation + Swift Standard Library over adding dependencies where feasible.
- Verify the package also builds on Linux (hermes1) — keep code cross-platform.
