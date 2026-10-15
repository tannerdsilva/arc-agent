import Testing

// the root of this target's serialized tree: every suite nests here (via
// `extension` blocks in its own file), so the trait serializes the whole
// target. `.serialized` covers a suite's entire subtree -- nested suites and
// extension-declared children included -- but has no effect on sibling suites,
// so nesting under one root is the only code-level way to serialize a target
// (the `--no-parallel` flag is the only other one, and it is not expressible
// in source). Measured 2026-10-14.
@Suite("Arc web UI tests", .serialized)
struct ArcWebUITestRoot {}
