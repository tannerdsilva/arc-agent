---
name: swift
description: Swift 6 capabilities on the arc-agent harness — structured concurrency, actors, and the two Laws.
---

# Swift

Work with Swift in strict-concurrency mode.

- Adopt the **First Law**: `async`/`await`, actors, `TaskGroup`/`AsyncStream`. Never hand-spawn threads, locks, dispatch queues, or semaphores.
- Adopt the **Second Law**: long-lived components are `Service`s managed by `swift-service-lifecycle`.
- Write **Swift Testing** tests (`import Testing`, `@Test`, `#expect`, `@Suite`). Never XCTest.
- Prefer protocols-first design; introduce macros only when a protocol abstraction becomes unwieldy.
- Keep code cross-platform for the Linux (hermes1) build.
