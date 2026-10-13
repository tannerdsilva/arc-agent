---
name: swift-testing
description: Write Swift Testing (not XCTest) tests with @Test/@Suite/#expect.
---

# Swift Testing

- Import `Testing`. Use `@Test`, `@Suite`, `#expect`, `#require`.
- Never use XCTest.
- For async suites sharing static seams, avoid parallel interference.
- If a test observes wrong-behavior first (RED), fix the code (GREEN), then refactor.
