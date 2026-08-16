import Foundation

/// The `memory` tool: read and write persistent memory.
///
/// Uses the same `FileMemoryProvider` that the agent uses for its system
/// prompt injection. This tool allows the LLM to save durable facts that
/// persist across sessions.
struct MemoryTool {

    static let entry = ToolEntry(
        name: "memory",
        toolset: "core",
        description: "Read from or write to persistent memory. "
            + "Memory is injected into every future turn, so keep entries "
            + "compact and high-signal. Use 'action: add' to save a fact, "
            + "'action: read' to view current memory.",
        schema: .object(
            description: "Memory operation parameters",
            properties: [
                "action": .enum(
                    description: "Operation: 'read' to view memory, 'add' to save a fact",
                    values: ["read", "add"]
                ),
                "content": .string(
                    description: "Content to save (required for 'add' action)"
                ),
            ],
            required: ["action"]
        ),
        handler: { args in
            let action = args["action"] as? String ?? "read"
            let content = args["content"] as? String

            let memoryDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".arc/memories")
            let provider = FileMemoryProvider(directory: memoryDir)

            switch action {
            case "add":
                guard let content, !content.isEmpty else {
                    return "Error: 'content' is required for 'add' action."
                }
                try await provider.appendMemory(content)
                return "Saved to memory."

            case "read":
                let memoryContent = try await provider.readMemory()
                if memoryContent.isEmpty {
                    return "No memory entries found."
                }
                return memoryContent

            default:
                return "Error: Unknown action '\(action)'. Use 'read' or 'add'."
            }
        },
        emoji: "🧠"
    )
}
