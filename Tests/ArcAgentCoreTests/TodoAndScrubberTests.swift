import Testing
@testable import ArcAgentCore
import Foundation

// =========================================================================
// MARK: - StreamingThinkScrubber (reference `agent/think_scrubber.py`)
// =========================================================================

/// State-machine probe of ``StreamingThinkScrubber``: partial-tag
/// hold-back, boundary gating, orphan-close stripping, flush semantics,
/// and re-entrancy (reset between turns).
@Suite("StreamingThinkScrubber")
struct StreamingThinkScrubberTests {

    /// Drive a full stream (array of deltas) and return the visible text.
    private func drive(_ deltas: [String]) -> String {
        var s = StreamingThinkScrubber()
        var out = ""
        for d in deltas { out += s.feed(d) }
        out += s.flush()
        return out
    }

    @Test("closed single block is suppressed")
    func closedSingle() {
        #expect(drive(["<thinking>reasoning</thinking>Hello world"]) == "Hello world")
    }

    @Test("all tag variants are handled case-insensitively")
    func variants() {
        for variant in ["think", "thinking", "reasoning", "thought", "REASONING_SCRATCHPAD"] {
            #expect(drive(["<\(variant)>x</\(variant)>Hello"]) == "Hello")
        }
    }

    @Test("unterminated open at start of stream is held and discarded")
    func openStart() {
        #expect(drive(["<thinking>reasoning text with no close"]) == "")
    }

    @Test("prose that merely mentions a tag is not suppressed")
    func proseMention() {
        #expect(drive(["Use the <thinking> element for reasoning"]) == "Use the <thinking> element for reasoning")
    }

    @Test("orphan close tag is stripped from prose")
    func orphanClose() {
        #expect(drive(["Hello</thinking>world"]) == "Helloworld")
    }

    @Test("split open tag across deltas is resolved")
    func splitOpenHeld() {
        #expect(drive(["<", "think>reasoning</thinking>done"]) == "done")
    }

    @Test("split tag in mid-sentence prose is preserved (boundary gating)")
    func splitMidline() {
        // Mid-line open is NOT a block boundary (reference boundary rule),
        // so the open tag survives as prose even when the close tag is
        // stripped. The split "<" + "think>" rejoins to "<think>".
        // Verified byte-for-byte against reference `think_scrubber.py`.
        #expect(drive(["word<", "think>prose</thinking>more"]) == "word<think>prosemore")
    }

    @Test("streaming block across many deltas is suppressed")
    func minimax() {
        #expect(drive(["<thinking>", "Let me check their config", "</thinking>", "done"]) == "done")
    }

    @Test("unterminated streamed block discards held reasoning")
    func minimaxUnterminated() {
        #expect(drive(["<thinking>", "The user wants", " to know something"]) == "")
    }

    @Test("whitespace before a boundary open is stripped with the block")
    func stripWhitespace() {
        #expect(drive(["word\n <thinking></thinking>", "rest"]) == "word\n rest")
    }

    @Test("reset clears state between turns")
    func resetClears() {
        var s = StreamingThinkScrubber()
        _ = s.feed("<thinking>leak")
        s.reset()
        #expect(s.feed("fresh text") == "fresh text")
    }

    @Test("flush emits held-back prose that was not a real tag")
    func flushProse() {
        var s = StreamingThinkScrubber()
        #expect(s.feed("Hello <thin") == "Hello ")
        #expect(s.flush() == "<thin")
    }
}

// =========================================================================
// MARK: - TodoStore / TodoTool (reference `tools/todo_tool.py`)
// =========================================================================

@Suite("TodoStore")
struct TodoStoreTests {

    @Test("write replaces the whole list when merge=false")
    func replace() async {
        let store = TodoStore()
        await store.write([TodoItem(id: "1", content: "first", status: "pending")], merge: false)
        let after = await store.write(
            [TodoItem(id: "2", content: "second", status: "in_progress")],
            merge: false
        )
        #expect(after.map(\.id) == ["2"])
    }

    @Test("merge=true updates by id and appends new items")
    func merge() async {
        let store = TodoStore()
        await store.write([TodoItem(id: "1", content: "old", status: "pending")], merge: false)
        let after = await store.write(
            [TodoItem(id: "1", content: "new", status: "completed"), TodoItem(id: "2", content: "two", status: "pending")],
            merge: true
        )
        #expect(after.count == 2)
        #expect(after.first?.content == "new")
        #expect(after.first?.status == "completed")
    }

    @Test("dedupe by id keeps the last occurrence")
    func dedupe() {
        let deduped = TodoStore.dedupeByID([
            TodoItem(id: "a", content: "1", status: "pending"),
            TodoItem(id: "a", content: "2", status: "pending"),
            TodoItem(id: "b", content: "3", status: "pending"),
        ])
        #expect(deduped.count == 2)
        #expect(deduped.first { $0.id == "a" }?.content == "2")
    }

    @Test("validate normalizes status and caps content")
    func validate() {
        let item = TodoStore.validate(TodoItem(
            id: "1",
            content: String(repeating: "x", count: 10_000),
            status: "IN_PROGRESS"
        ))
        #expect(item.status == "in_progress")
        #expect(item.content.count <= TodoStore.maxContentChars)
        #expect(item.content.contains(TodoStore.truncationMarker))
    }

    @Test("injection block includes only active items")
    func injection() async {
        let store = TodoStore()
        await store.write([
            TodoItem(id: "1", content: "active", status: "in_progress"),
            TodoItem(id: "2", content: "done", status: "completed"),
        ], merge: false)
        let block = await store.injectionBlock()
        #expect(block?.contains("active") == true)
        #expect(block?.contains("done") == false)
    }

    @Test("empty list has no injection block")
    func injectionEmpty() async {
        let store = TodoStore()
        #expect(await store.injectionBlock() == nil)
    }

    @Test("max items bound is enforced")
    func maxItems() async {
        let store = TodoStore()
        let many = (0..<300).map { TodoItem(id: "\($0)", content: "c\($0)", status: "pending") }
        let after = await store.write(many, merge: false)
        #expect(after.count == TodoStore.maxItems)
    }
}

@Suite("TodoTool")
struct TodoToolTests {

    @Test("tool entry is registered under the todo toolset")
    func entryType() {
        #expect(TodoTool.entry.name == "todo")
        #expect(TodoTool.entry.toolset == "todo")
        #expect(TodoTool.entry.emoji == "📋")
    }

    @Test("render returns a parseable JSON payload with summary")
    func render() async {
        let rendered = TodoTool.render([
            TodoItem(id: "1", content: "one", status: "pending"),
            TodoItem(id: "2", content: "two", status: "completed"),
        ])
        let data = rendered.data(using: .utf8)!
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let summary = json["summary"] as! [String: Any]
        #expect(summary["total"] as? Int == 2)
        #expect(summary["pending"] as? Int == 1)
        #expect(summary["completed"] as? Int == 1)
        let todos = json["todos"] as! [[String: Any]]
        #expect(todos.count == 2)
    }
}
