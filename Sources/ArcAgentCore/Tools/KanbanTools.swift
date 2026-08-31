import Foundation

/// Kanban tools for the LLM to interact with the kanban board.
///
/// These tools allow the agent to create, list, show, and complete tasks
/// on the kanban board. The board reference is set at agent startup.
struct KanbanTools {

    nonisolated(unsafe) static var board: (any KanbanBoard)?

    /// Create a new kanban task.
    static let create = ToolEntry(
        name: "kanban_create",
        toolset: "kanban",
        description: "Create a new task on the kanban board.",
        schema: .object(
            description: "Task creation parameters",
            properties: [
                "title": .string(description: "Short task title"),
                "body": .string(description: "Full description"),
                "assignee": .string(description: "Assignee profile name"),
                "priority": .integer(description: "Priority (higher = more urgent)"),
            ],
            required: ["title"]
        ),
        handler: { args in
            guard let board = KanbanTools.board else {
                return "Error: Kanban board not available."
            }
            let title = args["title"] as? String ?? "Untitled"
            let body = args["body"] as? String ?? ""
            let assignee = args["assignee"] as? String
            let priority = args["priority"] as? Int ?? 0

            let task = KanbanTask(
                title: title,
                body: body,
                assignee: assignee,
                priority: priority
            )
            try await board.create(task)
            return "Task created: \(task.id)"
        },
        emoji: "📋"
    )

    /// List kanban tasks with optional filters.
    static let list = ToolEntry(
        name: "kanban_list",
        toolset: "kanban",
        description: "List tasks on the kanban board with optional status and assignee filters.",
        schema: .object(
            description: "List parameters",
            properties: [
                "status": .string(description: "Filter by status (todo, ready, running, blocked, done)"),
                "assignee": .string(description: "Filter by assignee"),
                "limit": .integer(description: "Max results (default 20)"),
            ],
            required: []
        ),
        handler: { args in
            guard let board = KanbanTools.board else {
                return "Error: Kanban board not available."
            }
            let statusFilter = (args["status"] as? String).flatMap { TaskStatus(rawValue: $0) }
            let assigneeFilter = args["assignee"] as? String
            let limit = args["limit"] as? Int ?? 20

            let tasks = try await board.list(status: statusFilter, assignee: assigneeFilter, limit: limit)
            guard !tasks.isEmpty else {
                return "No tasks found."
            }
            var result = "Kanban Tasks:\n"
            for task in tasks {
                result += "  [\(task.status.rawValue)] \(task.id.prefix(8))... \(task.title.prefix(50))\n"
            }
            return result
        },
        emoji: "📋"
    )

    /// Show a single task's full details.
    static let show = ToolEntry(
        name: "kanban_show",
        toolset: "kanban",
        description: "Show full details of a kanban task by ID.",
        schema: .object(
            description: "Show parameters",
            properties: [
                "id": .string(description: "Task ID"),
            ],
            required: ["id"]
        ),
        handler: { args in
            guard let board = KanbanTools.board else {
                return "Error: Kanban board not available."
            }
            let id = args["id"] as? String ?? ""
            guard let task = try await board.get(id: id) else {
                return "Error: Task '\(id)' not found."
            }
            return """
            Task: \(task.title)
            Status: \(task.status.rawValue)
            Assignee: \(task.assignee ?? "unassigned")
            Priority: \(task.priority)
            Created: \(task.createdAt)
            Body: \(task.body.prefix(500))
            """
        },
        emoji: "📖"
    )

    /// Complete a task with a result summary.
    static let complete = ToolEntry(
        name: "kanban_complete",
        toolset: "kanban",
        description: "Mark a kanban task as done with a result summary.",
        schema: .object(
            description: "Complete parameters",
            properties: [
                "id": .string(description: "Task ID"),
                "summary": .string(description: "Result summary"),
            ],
            required: ["id"]
        ),
        handler: { args in
            guard let board = KanbanTools.board else {
                return "Error: Kanban board not available."
            }
            let id = args["id"] as? String ?? ""
            let summary = args["summary"] as? String

            guard var task = try await board.get(id: id) else {
                return "Error: Task '\(id)' not found."
            }
            task.status = .done
            task.result = summary
            try await board.update(task)
            return "Task \(id.prefix(8))... marked as done."
        },
        emoji: "✅"
    )

    /// Block a task with a reason.
    static let block = ToolEntry(
        name: "kanban_block",
        toolset: "kanban",
        description: "Block a task with a reason (moves to blocked status).",
        schema: .object(
            description: "Block parameters",
            properties: [
                "id": .string(description: "Task ID"),
                "reason": .string(description: "Why the task is blocked"),
            ],
            required: ["id", "reason"]
        ),
        handler: { args in
            guard let board = KanbanTools.board else {
                return "Error: Kanban board not available."
            }
            let id = args["id"] as? String ?? ""
            let reason = args["reason"] as? String ?? "No reason given"

            try await board.transition(id: id, to: .blocked)
            return "Task \(id.prefix(8))... blocked: \(reason)"
        },
        emoji: "🚫"
    )
}
