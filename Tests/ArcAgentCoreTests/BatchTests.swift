import Foundation
import Testing
@testable import ArcAgentCore

// MARK: - Batch processing (reference `batch_runner.py`)

@Suite("Batch trajectories")
struct BatchTests {

    @Test("ShareGPT conversion matches the reference shape")
    func trajectoryShape() {
        let messages: [Message] = [
            Message(role: .user, content: "Add a doc note"),
            Message(
                role: .assistant,
                content: "Let me look at the file.",
                toolCalls: [ToolCall(id: "call_1", type: "function", function: ToolCallFunction(name: "read_file", arguments: "{\"path\": \"/tmp/a.txt\"}"))]
            ),
            Message(role: .tool, content: "file content", name: "read_file", toolCallID: "call_1"),
            Message(role: .assistant, content: "Done. I added the note.", reasoning: "I organized the steps."),
        ]
        let trajectory = ShareGPTTrajectory.make(
            messages: messages,
            userQuery: "Add a doc note",
            completed: true,
            toolsIndexText: "read_file: Read a file\nwrite_file: Write a file"
        )
        #expect(trajectory.count == 5)
        #expect(trajectory[0].from == "system")
        #expect(trajectory[0].value.contains("<tools>"))
        #expect(trajectory[0].value.contains("read_file: Read a file"))
        #expect(trajectory[1].from == "human")
        #expect(trajectory[1].value == "Add a doc note")

        // GPT turn with tool call: 思考 block + tool_call XML.
        #expect(trajectory[2].from == "gpt")
        #expect(trajectory[2].value.contains("思考"))
        #expect(trajectory[2].value.contains("<tool_call>"))
        #expect(trajectory[2].value.contains("read_file"))

        // All tool responses of a turn joined into one message.
        #expect(trajectory[3].from == "tool")
        #expect(trajectory[3].value.contains("tool_call_id"))
        #expect(trajectory[3].value.contains("read_file"))

        // Final assistant turn (reasoning + reply).
        #expect(trajectory[4].from == "gpt")
        #expect(trajectory[4].value.contains("Done. I added the note."))
        #expect(trajectory[4].value.contains("I organized the steps."))
    }

    @Test("conversion keeps 思考 blocks on every gpt turn")
    func ghostBlocks() {
        let messages: [Message] = [
            Message(role: .user, content: "hi"),
            Message(role: .assistant, content: "hello", reasoning: nil),
        ]
        let trajectory = ShareGPTTrajectory.make(messages: messages, userQuery: "hi", completed: true, toolsIndexText: "")
        #expect(trajectory[2].from == "gpt")
        #expect(trajectory[2].value.hasPrefix("思考\n思考\n"))
    }

    @Test("tool result error classification matches reference semantics")
    func errorClassification() {
        #expect(ToolCallStat.resultIsError("Error: file not found"))
        #expect(ToolCallStat.resultIsError("ERROR: nope"))
        #expect(ToolCallStat.resultIsError(""))
        #expect(ToolCallStat.resultIsError("{\"error\": \"boom\"}"))
        #expect(ToolCallStat.resultIsError("{\"success\": false}"))
        #expect(!ToolCallStat.resultIsError("all good"))
        #expect(!ToolCallStat.resultIsError("{\"success\": true}"))
        #expect(!ToolCallStat.resultIsError("{\"error\": null, \"content\": \"ok\"}"))
    }

    @Test("dataset loader handles prompt and conversations forms")
    func datasetLoading() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-batch-data-\(UUID().uuidString).jsonl")
        let lines = [
            "{\"prompt\": \"first\"}",
            "{\"conversations\": [{\"role\": \"system\", \"content\": \"sys\"}, {\"role\": \"user\", \"content\": \"second\"}]}",
            "{\"conversations\": [{\"from\": \"human\", \"value\": \"third\"}]}",
            "not-json",
            "",
        ].joined(separator: "\n")
        try lines.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let entries = try BatchDatasetLoader.load(url)
        #expect(entries.map(\.prompt) == ["first", "second", "third"])
    }

    @Test("distribution sampling is deterministic per seed and honors weights")
    func distributionSampling() {
        let universe = ["web", "terminal", "file", "browser"]
        let research = BatchDistribution.named("research", universe: universe)!
        // Same seed → same subset.
        let a = research.sample(seed: 42, universe: universe)
        let b = research.sample(seed: 42, universe: universe)
        #expect(a == b)
        // Default includes everything.
        let def = BatchDistribution.named("default", universe: universe)!
        #expect(def.sample(seed: 7, universe: universe) == Set(universe))
        // Weight 0 never selected.
        let never = BatchDistribution(name: "x", description: "x", weights: ["browser": 0])
        #expect(!never.sample(seed: 1, universe: universe).contains("browser"))
    }

    @Test("trajectory entry JSON uses the reference snake_case keys")
    func entryEncoding() throws {
        let entry = TrajectoryEntry(
            promptIndex: 3,
            conversations: [TrajectoryChatMessage(from: "human", value: "x")],
            metadata: ["batch_num": "0", "model": "m"],
            completed: true, partial: false, apiCalls: 1,
            toolsetsUsed: ["file"], toolStats: ["write_file": ToolCallStat()]
        )
        let data = try JSONEncoder().encode(entry)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["prompt_index"] as? Int == 3)
        #expect(json["api_calls"] as? Int == 1)
        #expect(json["toolsets_used"] as? [String] == ["file"])
        #expect(json["tool_stats"] is [String: Any])
        #expect(json["tool_error_counts"] is [String: Any])
    }
}
