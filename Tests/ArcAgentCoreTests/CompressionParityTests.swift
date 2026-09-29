import Testing
@testable import ArcAgentCore
import Foundation

/// reference context-compressor parity tests: window selection, pruning,
/// orphan cleanup, structured summary template (Resolved/Pending), and
/// memory recall (trivial-prompt guard + fenced block).
@Suite("Context compression parity")
struct CompressionParityTests {

    private func msg(_ role: Message.Role, _ content: String, id: String? = nil, name: String? = nil) -> Message {
        Message(role: role, content: content, name: name, toolCallID: id)
    }

    private let counter = TokenCounter()

    @Test("window protects head (first exchange) and tail budget floor of 4")
    func windowSelection() {
        var msgs = [Message(role: .system, content: "sys")]
        msgs += [msg(.user, "u1"), msg(.assistant, "a1")]
        msgs += (0..<10).map { msg(.user, "m\($0)") }
        msgs += [msg(.user, "u-last"), msg(.assistant, "a-last")]

        let w = ContextCompression.window(
            msgs,
            tailBudget: 10_000,
            countTokens: { counter.count($0, model: "gpt-4o") }
        )
        // Head = first exchange (2 non-system).
        #expect(w.head.count == 2)
        #expect(w.head[0].content == "u1")
        #expect(w.head[1].content == "a1")
        // Tail = the final exchange (budget large enough to swallow all).
        #expect(!w.tail.isEmpty)
        #expect(w.tail.last?.content == "a-last")
        // Everything between head and tail is compressible.
        #expect(w.head.count + w.middle.count + w.tail.count == msgs.count - 1)

        // Tiny budget: floor of at least 4 tail messages.
        let w2 = ContextCompression.window(
            msgs,
            tailBudget: 4,
            countTokens: { _ in 1 }
        )
        #expect(w2.tail.count >= 4)
    }

    @Test("prune replaces oversized tool results, keeps metadata")
    func pruneOversizedTools() {
        let big = String(repeating: "x", count: 4_000)
        let small = "ok"
        let pruned = ContextCompression.pruneToolResults([
            msg(.tool, big, id: "t1", name: "terminal"),
            msg(.tool, small, id: "t2", name: "read_file"),
            msg(.user, big),
        ])
        #expect(pruned[0].content == "[Old tool output cleared to save context space]")
        #expect(pruned[0].toolCallID == "t1")
        #expect(pruned[0].name == "terminal")
        #expect(pruned[1].content == small)
        #expect(pruned[2].content == big) // non-tool untouched
    }

    @Test("orphan cleanup drops tool results with no surviving call")
    func orphanCleanup() {
        let kept = msg(.tool, "result", id: "keep", name: "search")
        let orphan = msg(.tool, "result", id: "gone", name: "search")
        let assistant = Message(role: .assistant, content: "calling", toolCallID: "keep")
        let cleaned = ContextCompression.orphanCleanup([kept, orphan, assistant])
        #expect(cleaned.contains { $0.toolCallID == "keep" })
        #expect(!cleaned.contains { $0.toolCallID == "gone" })
    }

    @Test("first summary prompt uses the reference structured template")
    func firstPromptStructure() {
        let material = [msg(.user, "build a parser"), msg(.tool, "output", name: "terminal")]
        let p = ContextCompression.firstSummaryPrompt(material: material, focus: "parsing", memoryContext: "user loves Swift")
        #expect(p.hasUserTurns == true)
        #expect(p.userContent.contains("## Historical Task Snapshot"))
        #expect(p.userContent.contains("## Goal"))
        #expect(p.userContent.contains("## Completed Actions"))
        #expect(p.userContent.contains("## Active State"))
        #expect(p.userContent.contains("## Blocked"))
        #expect(p.userContent.contains("## Key Decisions"))
        #expect(p.userContent.contains("## Resolved Questions"))
        #expect(p.userContent.contains("## Historical Pending User Asks"))
        #expect(p.userContent.contains("## Relevant Files"))
        #expect(p.userContent.contains("## Critical Context"))
        #expect(p.userContent.contains("[REDACTED]"))
        #expect(p.userContent.contains("FOCUS TOPIC: \"parsing\""))
        #expect(p.userContent.contains("MEMORY CONTEXT"))
        #expect(p.userContent.contains("User asked:"))
        #expect(p.userContent.contains("[Tool terminal]: output"))
    }

    @Test("no-user-turn sessions use the sentinel, not invented users")
    func noUserPrompt() {
        let material = [msg(.assistant, "work done"), msg(.tool, "out", name: "x")]
        let p = ContextCompression.firstSummaryPrompt(material: material, focus: nil, memoryContext: "")
        #expect(p.hasUserTurns == false)
        #expect(p.userContent.contains(ContextCompression.noUserTaskSentinel))
        // The instruction forbids the phrase *in prose*, but the rule text
        // itself quotes it — assert no quoted EXAMPLES are present.
        #expect(!p.userContent.contains("User asked: '<exact"))
    }

    @Test("update prompt folds previous summary with new turns")
    func updatePromptStructure() {
        let p = ContextCompression.updateSummaryPrompt(
            previousSummary: "## Historical Task Snapshot\n...",
            newTurns: [msg(.user, "more work")],
            focus: nil,
            memoryContext: ""
        )
        #expect(p.userContent.contains("PREVIOUS SUMMARY:"))
        #expect(p.userContent.contains("NEW TURNS TO INCORPORATE:"))
        #expect(p.userContent.contains("Move answered questions to \"Resolved Questions\""))
        #expect(p.userContent.contains("Update the summary using this exact structure"))
    }

    @Test("bound summary input caps pathological summaries")
    func boundSummary() {
        let big = String(repeating: "y", count: 100_000)
        let bounded = ContextCompression.boundSummaryInput(big, budget: 2_000)
        #expect(bounded.contains("truncated"))
        #expect(bounded.count < big.count)
    }

    @Test("trivial prompts skip memory recall")
    func trivialPrompts() {
        for trivial in ["", "   ", "hi", "hey!", "ok", "thanks :)", "done???", "/help", "/model gpt-4"] {
            #expect(MemoryRecall.isTrivialPrompt(trivial), "expected trivial: \(trivial)")
        }
        for real in ["please add a file watcher", "check the API for errors", "yes, and also fix the tests", "hey can you check that build", "continue with the migration tomorrow"] {
            #expect(!MemoryRecall.isTrivialPrompt(real), "expected non-trivial: \(real)")
        }
        #expect(MemoryRecall.isTrivialPrompt(nil))
    }

    @Test("recall block wraps provider context with the system note")
    func recallBlock() {
        #expect(MemoryManager.recallBlock("") == nil)
        #expect(MemoryManager.recallBlock("   \n  ") == nil)
        let block = MemoryManager.recallBlock("server runs Ubuntu")
        #expect(block?.hasPrefix("<memory-context>") == true)
        #expect(block?.contains("[System note: The following is recalled memory context") == true)
        #expect(block?.hasSuffix("</memory-context>") == true)
        #expect(block?.contains("server runs Ubuntu") == true)
    }
}
