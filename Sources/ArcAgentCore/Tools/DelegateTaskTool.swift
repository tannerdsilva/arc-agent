import Foundation

/// The `delegate_task` tool: spawn a subagent to work on a task.
///
/// This is the primary mechanism for multi-agent orchestration. The parent
/// agent delegates a task to a child subagent, which runs in an isolated
/// context and returns a summary when done.
///
/// ## Toolset Intersection
///
/// The child receives a filtered tool registry containing only the toolsets
/// specified in `allowedToolsets`. If empty, the child has no tools.
struct DelegateTaskTool {

    /// Reference to the delegation manager, set at registration time.
    /// `nonisolated(unsafe)` is safe because the reference is set once in
    /// `ArcAgent.run()` and only read from tool handlers.
    nonisolated(unsafe) static var manager: DelegationManager?

    static let entry = ToolEntry(
        name: "delegate_task",
        toolset: "delegation",
        description: "Spawn a subagent to work on a task in isolation. "
            + "The subagent runs independently and returns a summary when done. "
            + "Use for reasoning-heavy subtasks, parallel work, or tasks that "
            + "would flood your context with intermediate data.",
        schema: .object(
            description: "Delegation parameters",
            properties: [
                "goal": .string(
                    description: "What the subagent should accomplish. Be specific and self-contained."
                ),
                "context": .string(
                    description: "Background information the subagent needs."
                ),
                "allowed_toolsets": .string(
                    description: "Comma-separated toolset names the subagent may use (e.g. 'file,web')."
                ),
            ],
            required: ["goal"]
        ),
        handler: { args in
            guard let manager = DelegateTaskTool.manager else {
                return "Error: Delegation manager not available."
            }
            let goal = args["goal"] as? String ?? ""
            let context = args["context"] as? String ?? ""
            let toolsets = (args["allowed_toolsets"] as? String)?
                .split(separator: ",")
                .map(String.init)
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? []

            let id = try await manager.spawn(
                goal: goal,
                context: context,
                allowedToolsets: toolsets
            )

            // Wait for the subagent to complete
            var attempts = 0
            while attempts < 600 {  // ~60s max wait
                if let agent = await manager.agent(id: id) {
                    switch agent.status {
                    case .completed:
                        return agent.summary ?? "Task completed with no summary."
                    case .failed:
                        return "Task failed: \(agent.errorMessage ?? "Unknown error")"
                    case .cancelled:
                        return "Task was cancelled."
                    case .running:
                        try await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                        attempts += 1
                    }
                }
            }

            return "Task timed out waiting for subagent to complete."
        },
        emoji: "🔄"
    )
}
