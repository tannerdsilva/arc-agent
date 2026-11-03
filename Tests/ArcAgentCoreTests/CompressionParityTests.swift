import Testing
@testable import ArcAgentCore
import Foundation

extension ArcCoreTestRoot {
    /// reference context-compressor parity tests: window selection, pruning,
    /// orphan cleanup, structured summary template (Resolved/Pending), and
    /// memory recall (trivial-prompt guard + fenced block).
    @Suite("Context compression parity", .serialized)
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

            // Small budget: the protect floor (4) holds while it fits the
            // soft ceiling (tailBudget × 1.5) — a run of bulky outputs is
            // capped by the ceiling, not frozen verbatim (reference
            // _find_tail_cut_by_tokens).
            let w2 = ContextCompression.window(
                msgs,
                tailBudget: 40,
                countTokens: { _ in 1 }
            )
            #expect(w2.tail.count >= 4)
            // Bulky-run cap: a ceiling of 6 tokens stops the walk at ~1
            // message even though the floor asks for 4.
            let w3 = ContextCompression.window(
                msgs,
                tailBudget: 4,
                countTokens: { _ in 1 }
            )
            #expect(w3.tail.count < 4)
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
            // Real message shape: assistant declares its calls through `toolCalls`
            // (regression: the old code only read `toolCallID`, so every tool
            // result was dropped as an orphan after a compression).
            let kept2 = msg(.tool, "result", id: "keep2", name: "search")
            let assistant2 = Message(
                role: .assistant, content: nil,
                toolCalls: [ToolCall(id: "keep2", function: ToolCallFunction(name: "search", arguments: "{}"))]
            )
            let cleaned2 = ContextCompression.orphanCleanup([kept2, assistant2])
            #expect(cleaned2.contains { $0.toolCallID == "keep2" },
                "tool results declared via toolCalls must be kept")
            let orphan2 = msg(.tool, "result", id: "gone2", name: "search")
            let cleaned3 = ContextCompression.orphanCleanup([orphan2, assistant2])
            #expect(!cleaned3.contains { $0.toolCallID == "gone2" })
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

        // MARK: - Hermes-scheme behaviors (Phase 1 / boundaries / defenses)

        private func toolMsg(_ name: String, _ content: String, id: String) -> Message {
            Message(role: .tool, content: content, name: name, toolCallID: id)
        }

        private func callMsg(_ name: String, _ args: String, id: String) -> Message {
            Message(
                role: .assistant,
                content: nil,
                toolCalls: [ToolCall(
                    id: id,
                    type: "function",
                    function: ToolCallFunction(name: name, arguments: args)
                )]
            )
        }

        @Test("Phase 1: informative one-line summaries, dedup, arg truncation, skill tombstones")
        func phaseOnePrune() {
            let big = String(repeating: "x", count: 5_000)
            let small = "exit 0"
            let args = String(repeating: "a", count: 2_000)
            var msgs: [Message] = [
                callMsg("terminal", args, id: "c1"),
                toolMsg("terminal", big, id: "c1"),
                callMsg("read_file", "{}", id: "c2"),
                toolMsg("read_file", small, id: "c2"),
                toolMsg("read_file", small, id: "c3"), // duplicate of c2's result
                toolMsg("skill_view", "---\nname: arc-agent-harness\n---\n" + big, id: "c4"),
            ]
            let out = ContextCompression.pruneOutsideTail(msgs)
            // the oversized result becomes a one-liner with shape info
            #expect(out[1].content?.contains("pruned") == true)
            #expect(out[1].content?.contains("terminal") == true)
            // the duplicated result is demoted, the newest stays verbatim
            #expect(out[3].content?.contains("pruned") == true)
            #expect(out[4].content == small)
            // skill_view body becomes the exact tombstone
            #expect(out[5].content == "[SKILL_PRUNED: arc-agent-harness]")
            // tool rows keep their ids (pairs stay repairable)
            #expect(out[5].toolCallID == "c4")
            // small results untouched, but bulky args truncated
            #expect(out[0].toolCalls?.first?.function.arguments.count ?? 0 < 1_100)
            _ = msgs // mutability not needed
        }

        @Test("Tail cut never splits a tool group and keeps the latest user turn")
        func atomicBoundaries() {
            var msgs: [Message] = (0..<8).map { msg(.user, "m\($0)") }
            msgs.append(callMsg("terminal", "{}", id: "t1"))
            msgs.append(toolMsg("terminal", "output", id: "t1"))
            msgs.append(msg(.user, "the real ask"))
            let w = ContextCompression.window(
                msgs,
                tailBudget: 1, // ceiling forces a minimal tail
                countTokens: { _ in 1 }
            )
            // the assistant call and its result land in the SAME region
            let callInTail = w.tail.contains { $0.role == .assistant && ($0.toolCalls?.first?.id == "t1") }
            let resultInTail = w.tail.contains { $0.toolCallID == "t1" }
            #expect(callInTail == resultInTail)
            // the most recent user message is in the tail
            #expect(w.tail.contains { $0.role == .user && $0.content == "the real ask" })
        }

        @Test("Secret redaction happens at serialization, before the aux model")
        func redaction() {
            let line = "[Tool terminal]: ran with api_key = supersecretvalue12345 and bearer AbCdEf0123456789abcdef"
            let record = ContextCompression.compressedRecord([msg(.user, line)])
            #expect(!record.contains("supersecretvalue12345"))
            #expect(record.contains("[REDACTED]"))
        }

        @Test("Ghost-skill defense: markers are collected then reinjected verbatim")
        func ghostSkills() {
            let material = [
                toolMsg("skill_view", "[SKILL_PRUNED: arc-agent-harness]", id: "c1"),
                msg(.assistant, "some skills were loaded"),
            ]
            let markers = ContextCompression.collectSkillMarkers(material)
            #expect(markers == ["[SKILL_PRUNED: arc-agent-harness]"])
            let summary = "Work summary. Some skills were loaded earlier."
            let reinjected = ContextCompression.reinjectSkillMarkers(summary, markers: markers)
            #expect(reinjected.contains("[SKILL_PRUNED: arc-agent-harness]"))
            // already-present markers are not duplicated
            let already = "[SKILL_PRUNED: arc-agent-harness]\nrest"
            #expect(ContextCompression.reinjectSkillMarkers(already, markers: markers) == already)
        }

        @Test("Pass 4 pressure demotion fires only when the protected region overshoots")
        func pressurePass() {
            let bigTool = toolMsg("terminal", String(repeating: "y", count: 50_000), id: "t9")
            let head = [msg(.user, "head")]
            let tail = [bigTool, msg(.user, "keep me"), msg(.assistant, "ok")]
            // 1.5× the tail budget in tokens: protected region far over
            let fired = ContextCompression.pressureDemote(
                head, tail, tailBudget: 100,
                countTokens: { text in text.count / 4 }
            )
            #expect(fired.fired)
            #expect(fired.tail.first?.content?.contains("pruned") == true)
            #expect(fired.tail.last?.content == "ok") // recent floor verbatim
            // a protected region that fits never fires
            let quiet = ContextCompression.pressureDemote(
                head, [msg(.user, "small")], tailBudget: 10_000,
                countTokens: { text in text.count / 4 }
            )
            #expect(!quiet.fired)
        }
    }
}
