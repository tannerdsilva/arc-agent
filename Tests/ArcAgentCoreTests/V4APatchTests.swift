import Foundation
import Testing
@testable import ArcAgentCore

/// V4A patch parser/validator/applier (Hermes parity): operations, hunks,
/// context hints, addition-only hunks, already-applied skips, and the
/// two-phase validate-then-apply contract.
@Suite("V4APatch")
struct V4APatchTests {

    /// In-memory file ops backing the tests.
    final class MockFileOps: V4AFileOps, @unchecked Sendable {
        var files: [String: String] = [:]
        var errors: [String: String] = [:]

        func readFileRaw(_ path: String) -> (String?, String?) {
            if let err = errors[path] { return (nil, err) }
            guard let content = files[path] else { return (nil, "file not found") }
            return (content, nil)
        }
        func writeFile(_ path: String, _ content: String) -> String? {
            files[path] = content
            return nil
        }
        func deleteFile(_ path: String) -> String? {
            files.removeValue(forKey: path)
            return nil
        }
        func moveFile(_ from: String, _ to: String) -> String? {
            guard let content = files.removeValue(forKey: from) else { return "file not found" }
            files[to] = content
            return nil
        }
    }

    @Test("parses update/add/delete/move operations")
    func parsesAllOperations() {
        let patch = """
        *** Begin Patch
        *** Update File: a.swift
        @@ foo @@
        -let x = 1
        +let x = 2
        *** Add File: b.swift
        +print(1)
        +print(2)
        *** Delete File: c.swift
        *** Move File: d.swift -> e.swift
        *** End Patch
        """
        let (ops, error) = V4APatch.parseV4APatch(patch)
        #expect(error == nil)
        #expect(ops.count == 4)
        #expect(ops[0].operation == .update)
        #expect(ops[0].filePath == "a.swift")
        #expect(ops[0].hunks[0].contextHint == "foo")
        #expect(ops[0].hunks[0].lines.count == 2)
        #expect(ops[1].operation == .add && ops[1].filePath == "b.swift")
        #expect(ops[2].operation == .delete && ops[2].filePath == "c.swift")
        #expect(ops[3].operation == .move && ops[3].filePath == "d.swift" && ops[3].newPath == "e.swift")
    }

    @Test("tolerates CRLF patch bodies")
    func crlfTolerated() {
        let patch = "*** Begin Patch\r\n*** Update File: a.txt\r\n-old\r\n+new\r\n*** End Patch\r\n"
        let (ops, error) = V4APatch.parseV4APatch(patch)
        #expect(error == nil)
        #expect(ops.count == 1)
        #expect(ops[0].hunks[0].lines[0].content == "old")
    }

    @Test("content lines that look like markers are not treated as markers")
    func markerLookalikesIgnored() {
        let patch = """
        *** Begin Patch
        *** Update File: doc.md
        -*** End Patch
        +*** Begin Patch
        *** End Patch
        """
        let (ops, error) = V4APatch.parseV4APatch(patch)
        #expect(error == nil)
        #expect(ops.count == 1)
        // the removed line is content, not a second operation
        #expect(ops[0].hunks[0].lines.count == 2)
    }

    @Test("update with no hunks is a parse error")
    func updateNeedsHunks() {
        let patch = "*** Begin Patch\n*** Update File: a.txt\n*** End Patch\n"
        let (ops, error) = V4APatch.parseV4APatch(patch)
        #expect(ops.isEmpty)
        #expect(error?.contains("no hunks found") == true)
    }

    @Test("empty patch is not an error")
    func emptyPatchOK() {
        let (ops, error) = V4APatch.parseV4APatch("")
        #expect(ops.isEmpty)
        #expect(error == nil)
    }

    @Test("apply performs update with fuzzy context")
    func applyUpdate() {
        let ops = V4APatch.parseV4APatch("""
        *** Begin Patch
        *** Update File: a.swift
        @@ marker @@
        -func a() {
        +func b() {
        -    return 1
        +    return 2
        -}
        +}
        *** End Patch
        """).operations
        let mock = MockFileOps()
        mock.files["a.swift"] = "func a() {\n    return 1\n}\n"
        let outcome = V4APatch.applyV4AOperations(ops, fileOps: mock)
        #expect(outcome.success)
        #expect(mock.files["a.swift"] == "func b() {\n    return 2\n}\n")
        #expect(outcome.filesModified == ["a.swift"])
        #expect(outcome.diff.contains("--- a/a.swift"))
    }

    @Test("apply add creates the file and reports it")
    func applyAdd() {
        let ops = V4APatch.parseV4APatch("""
        *** Begin Patch
        *** Add File: new.txt
        +hello
        +world
        *** End Patch
        """).operations
        let mock = MockFileOps()
        let outcome = V4APatch.applyV4AOperations(ops, fileOps: mock)
        #expect(outcome.success)
        #expect(mock.files["new.txt"] == "hello\nworld")
        #expect(outcome.filesCreated == ["new.txt"])
    }

    @Test("apply delete removes the file and emits a diff")
    func applyDelete() {
        let ops = V4APatch.parseV4APatch("*** Begin Patch\n*** Delete File: gone.txt\n*** End Patch\n").operations
        let mock = MockFileOps()
        mock.files["gone.txt"] = "byebye\n"
        let outcome = V4APatch.applyV4AOperations(ops, fileOps: mock)
        #expect(outcome.success)
        #expect(mock.files["gone.txt"] == nil)
        #expect(outcome.filesDeleted == ["gone.txt"])
    }

    @Test("apply move relocates content and blocks overwrite")
    func applyMove() {
        let ops = V4APatch.parseV4APatch("*** Begin Patch\n*** Move File: old.txt -> new.txt\n*** End Patch\n").operations
        let mock = MockFileOps()
        mock.files["old.txt"] = "content"
        mock.files["new.txt"] = "occupied"
        let outcome = V4APatch.applyV4AOperations(ops, fileOps: mock)
        #expect(outcome.success == false)
        #expect(outcome.error?.contains("destination already exists") == true)
        #expect(mock.files["old.txt"] == "content")
        mock.files.removeValue(forKey: "new.txt")
        let ok = V4APatch.applyV4AOperations(ops, fileOps: mock)
        #expect(ok.success)
        #expect(mock.files["new.txt"] == "content")
    }

    @Test("validation fails atomically before any write")
    func atomicValidation() {
        let ops = V4APatch.parseV4APatch("""
        *** Begin Patch
        *** Update File: real.txt
        -old
        +new
        *** Update File: missing.txt
        -nope
        +nope2
        *** End Patch
        """).operations
        let mock = MockFileOps()
        mock.files["real.txt"] = "old"
        let outcome = V4APatch.applyV4AOperations(ops, fileOps: mock)
        #expect(outcome.success == false)
        #expect(outcome.error?.contains("validation failed") == true)
        #expect(mock.files["real.txt"] == "old")  // untouched
    }

    @Test("already-applied hunk is skipped, not an error")
    func alreadyAppliedSkipped() {
        let ops = V4APatch.parseV4APatch("""
        *** Begin Patch
        *** Update File: real.txt
        -original text 42
        +replacement text 42
        *** End Patch
        """).operations
        let mock = MockFileOps()
        mock.files["real.txt"] = "replacement text 42"  // patch already landed
        let outcome = V4APatch.applyV4AOperations(ops, fileOps: mock)
        #expect(outcome.success)
        #expect(mock.files["real.txt"] == "replacement text 42")
    }

    @Test("addition-only hunk inserts after unique context hint")
    func additionOnlyWithHint() {
        let ops = V4APatch.parseV4APatch("""
        *** Begin Patch
        *** Update File: code.py
        @@ def foo(): @@
        +    # inserted line
        *** End Patch
        """).operations
        let mock = MockFileOps()
        mock.files["code.py"] = "def foo():\n    pass\n"
        let outcome = V4APatch.applyV4AOperations(ops, fileOps: mock)
        #expect(outcome.success)
        #expect(mock.files["code.py"] == "def foo():\n    # inserted line\n    pass\n")
    }

    @Test("ambiguous addition-only hint is an error")
    func ambiguousAdditionOnlyHint() {
        let ops = V4APatch.parseV4APatch("""
        *** Begin Patch
        *** Update File: code.py
        @@ pass @@
        +    x = 1
        *** End Patch
        """).operations
        let mock = MockFileOps()
        mock.files["code.py"] = "pass\npass\n"
        let outcome = V4APatch.applyV4AOperations(ops, fileOps: mock)
        #expect(outcome.success == false)
        #expect(outcome.error?.contains("ambiguous") == true)
    }

    @Test("context-hint fallback applies hunk near the hint")
    func hintFallback() {
        let ops = V4APatch.parseV4APatch("""
        *** Begin Patch
        *** Update File: big.txt
        @@ alpha @@
        -beta
        +BETA
        *** End Patch
        """).operations
        let mock = MockFileOps()
        // beta appears far from alpha; hunk pattern has extra whitespace drift
        let content = String(repeating: "filler line\n", count: 60) + "alpha\nbeta line\n"
        mock.files["big.txt"] = content
        let outcome = V4APatch.applyV4AOperations(ops, fileOps: mock)
        #expect(outcome.success == true)
        #expect(mock.files["big.txt"]?.contains("alpha\nBETA line\n") == true)
    }

    @Test("unified diff helper produces plus/minus lines")
    func unifiedDiffHelper() {
        let diff = unifiedDiff(old: "a\nb\n", new: "a\nc\n", oldPath: "a/x", newPath: "b/x")
        #expect(diff.contains("--- a/x"))
        #expect(diff.contains("+++ b/x"))
        #expect(diff.contains("-b"))
        #expect(diff.contains("+c"))
    }
}
