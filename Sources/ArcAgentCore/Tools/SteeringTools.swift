import Foundation

/// The `list_children` tool: list all subagents managed by the delegation system.
struct ListChildrenTool {

    nonisolated(unsafe) static var manager: DelegationManager?

    static let entry = ToolEntry(
        name: "list_children",
        toolset: "delegation",
        description: "List all subagents managed by the delegation system, "
            + "showing their ID, status, goal, and creation time.",
        schema: .object(
            description: "List children parameters (none required)",
            properties: [:]
        ),
        handler: { _ in
            guard let manager = ListChildrenTool.manager else {
                return "Error: Delegation manager not available."
            }
            let agents = await manager.allAgents
            guard !agents.isEmpty else {
                return "No subagents found."
            }
            var result = "Subagents:\n"
            for agent in agents {
                result += "  [\(agent.status.rawValue)] \(agent.id.prefix(8))... — \(agent.goal.prefix(60))\n"
            }
            return result
        },
        emoji: "📋"
    )
}

/// The `steer_child` tool: send a message to a running subagent.
struct SteerChildTool {

    nonisolated(unsafe) static var manager: DelegationManager?

    static let entry = ToolEntry(
        name: "steer_child",
        toolset: "delegation",
        description: "Send a message to a running subagent to adjust its direction.",
        schema: .object(
            description: "Steer parameters",
            properties: [
                "id": .string(description: "The subagent's ID"),
                "message": .string(description: "The message to send"),
            ],
            required: ["id", "message"]
        ),
        handler: { args in
            guard let manager = SteerChildTool.manager else {
                return "Error: Delegation manager not available."
            }
            let id = args["id"] as? String ?? ""
            let message = args["message"] as? String ?? ""

            do {
                try await manager.steer(id: id, message: message)
                return "Message sent to subagent \(id.prefix(8))..."
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        },
        emoji: "🎯"
    )
}

/// The `stop_child` tool: cancel a running subagent.
struct StopChildTool {

    nonisolated(unsafe) static var manager: DelegationManager?

    static let entry = ToolEntry(
        name: "stop_child",
        toolset: "delegation",
        description: "Cancel a running subagent by ID.",
        schema: .object(
            description: "Stop parameters",
            properties: [
                "id": .string(description: "The subagent's ID to cancel"),
            ],
            required: ["id"]
        ),
        handler: { args in
            guard let manager = StopChildTool.manager else {
                return "Error: Delegation manager not available."
            }
            let id = args["id"] as? String ?? ""

            do {
                try await manager.cancel(id: id)
                return "Subagent \(id.prefix(8))... cancelled."
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        },
        emoji: "⏹️"
    )
}
