import Foundation

/// The `delegate_task` tool: spawn a subagent to work on a task.
///
/// This is the primary mechanism for multi-agent orchestration. The parent
/// agent delegates a task to a child subagent, which runs as a real,
/// isolated agent (own context, filtered tool registry, focused goal
/// prompt) and returns its final answer when done.
///
/// ## Toolset Intersection
///
/// The child receives a filtered tool registry containing only the toolsets
/// specified in `allowedToolsets`. If empty, the child inherits all of the
/// parent's toolsets. The `delegation` toolset is always stripped, so
/// children cannot delegate (no recursion).
struct DelegateTaskTool {

    /// Reference to the delegation manager, set at registration time.
    /// `nonisolated(unsafe)` is safe because the reference is set once in
    /// `ArcAgent.run()` and only read from tool handlers.
    nonisolated(unsafe) static var manager: DelegationManager?

    static let entry = ToolEntry(
        name: "delegate_task",
        toolset: "delegation",
        description: "Spawn a subagent to work on a task in isolation. "
            + "The subagent runs independently with its own context and returns its "
            + "final answer when done. Use for reasoning-heavy subtasks, parallel work, "
            + "or tasks that would flood your context with intermediate data. "
            + "Empty allowed_toolsets inherits the parent's toolsets; children "
            + "cannot delegate further.",
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
                    description: "Comma-separated toolset names the subagent may use (e.g. 'file,web'); empty inherits all."
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

            // Wait for the real child to finish; the stream yields its final
            // answer (or the failure text) and then ends.
            guard let stream = await manager.stream(id: id) else {
                return "Error: No result stream for subagent \(id.prefix(8))."
            }
            var result = ""
            do {
                for try await chunk in stream {
                    result += chunk
                }
            } catch {
                return "Task failed: \(error)"
            }
            return result.isEmpty ? "Task completed with no summary." : result
        },
        emoji: "🔄"
    )
}
