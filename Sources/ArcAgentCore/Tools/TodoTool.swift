import Foundation

/// Session-scoped todo list (reference `tools/todo_tool.py`).
///
/// Mirrors the reference `TodoStore`: items are ordered (list position is
/// priority), each has `id`/`content`/`status`, and the list is re-injected
/// into the conversation after context-compression events
/// (``injectionBlock``). Bounds mirror the reference so a single oversized
/// item or replayed/forged history can't inflate the re-injection block.
///
/// An actor (First Law): tool handlers run concurrently under the parallel
/// batch executor, so list mutation must be serialized.
public actor TodoStore {

    public static let maxContentChars = 4_000
    public static let maxItems = 256
    public static let maxResultChars = 512_000
    static let truncationMarker = "… [truncated]"

    /// Stable header of the synthetic post-compaction row (reference
    /// `TODO_INJECTION_HEADER`). The compressor recognizes it so a real user
    /// message is never confused with the preserved task list.
    public static let injectionHeader = "[Your active task list was preserved across context compression]"

    /// Valid status values.
    public static let validStatuses: Set<String> = ["pending", "in_progress", "completed", "cancelled"]

    private var items: [TodoItem] = []

    public init() {}

    // MARK: - Read / write

    /// Read a copy of the current list.
    public func read() -> [TodoItem] {
        items
    }

    /// Write todos. Returns the full current list after writing.
    ///
    /// - Parameters:
    ///   - todos: the items to write (validated/normalized).
    ///   - merge: `false` replaces the whole list; `true` updates existing
    ///     items by id and appends new ones.
    public func write(_ todos: [TodoItem], merge: Bool) -> [TodoItem] {
        let deduped = Self.dedupeByID(todos)
        if !merge {
            items = deduped
        } else {
            var byID: [String: TodoItem] = [:]
            for item in items { byID[item.id] = item }
            for incoming in deduped {
                if let existing = byID[incoming.id] {
                    var updated = existing
                    if !incoming.content.isEmpty { updated.content = Self.cap(incoming.content) }
                    if !incoming.status.isEmpty { updated.status = Self.normalize(incoming.status) }
                    byID[incoming.id] = updated
                } else {
                    let validated = Self.validate(incoming)
                    byID[validated.id] = validated
                    items.append(validated)
                }
            }
            // Rebuild preserving order of existing items.
            var seen = Set<String>()
            var rebuilt: [TodoItem] = []
            for item in items {
                let current = byID[item.id] ?? item
                if !seen.contains(current.id) {
                    rebuilt.append(current)
                    seen.insert(current.id)
                }
            }
            items = rebuilt
        }
        if items.count > Self.maxItems {
            items = Array(items.prefix(Self.maxItems))
        }
        return items
    }

    /// Human-readable rendering for post-compression injection. Only
    /// pending/in_progress items are included — completed/cancelled ones
    /// would cause the model to re-do finished work after compression.
    /// Returns `nil` when there is nothing active to inject.
    public func injectionBlock() -> String? {
        let active = items.filter { $0.status == "pending" || $0.status == "in_progress" }
        guard !active.isEmpty else { return nil }
        let markers: [String: String] = [
            "completed": "[x]",
            "in_progress": "[>]",
            "pending": "[ ]",
            "cancelled": "[~]",
        ]
        var lines = [Self.injectionHeader]
        for item in active {
            let marker = markers[item.status] ?? "[?]"
            lines.append("- \(marker) \(item.id). \(item.content) (\(item.status))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Validation

    public static func validate(_ item: TodoItem) -> TodoItem {
        var content = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty { content = "(no description)" } else { content = cap(content) }
        let status = normalize(item.status)
        return TodoItem(id: item.id.isEmpty ? "?" : item.id, content: content, status: status)
    }

    public static func normalize(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return validStatuses.contains(s) ? s : "pending"
    }

    static func cap(_ content: String) -> String {
        guard content.count > maxContentChars else { return content }
        let keep = maxContentChars - truncationMarker.count
        return String(content.prefix(keep)) + truncationMarker
    }

    static func dedupeByID(_ todos: [TodoItem]) -> [TodoItem] {
        var lastIndex: [String: Int] = [:]
        for (i, item) in todos.enumerated() {
            lastIndex[item.id.isEmpty ? "?" : item.id] = i
        }
        return lastIndex.values.sorted().map { todos[$0] }
    }
}

/// One todo item (reference `todo_tool` item shape).
public struct TodoItem: Sendable, Codable, Equatable {
    public var id: String
    public var content: String
    public var status: String

    public init(id: String, content: String, status: String) {
        self.id = id
        self.content = content
        self.status = TodoStore.normalize(status)
    }
}

/// The `todo` tool: manage the session-scoped task list (reference
/// `tools/todo_tool.py`).
///
/// Single entry point — provide `todos` to write, omit to read. Every call
/// returns the full current list with a summary. Behavioral guidance lives in
/// the schema description (static, cache-friendly), exactly like reference.
enum TodoTool {

    /// Session-scoped store wired by the agent at startup (see
    /// ``ArcAgent/runConversation`` setup). Static so the handler closure
    /// (value-captured at registration) can reach the per-agent instance;
    /// Date-backed for tests only — production wires a per-agent store.
    nonisolated(unsafe) static var store: TodoStore?

    /// Fallback used when no store has been wired (e.g. `arc tools` listing).
    static let fallbackStore = TodoStore()

    static var entry = ToolEntry(
        name: "todo",
        toolset: "todo",
        description: "Manage your task list for the current session. Use for complex tasks "
            + "with 3+ steps or when the user provides multiple tasks. "
            + "Call with no parameters to read the current list.\n\n"
            + "Writing:\n"
            + "- Provide 'todos' array to create/update items\n"
            + "- merge=false (default): replace the entire list with a fresh plan\n"
            + "- merge=true: update existing items by id, add any new ones\n\n"
            + "Each item: {id: string, content: string, status: pending|in_progress|completed|cancelled}\n"
            + "List order is priority. Only ONE item in_progress at a time.\n"
            + "Mark items completed immediately when done. If something fails, "
            + "cancel it and add a revised item.\n\n"
            + "Always returns the full current list.",
        schema: .object(
            description: "Todo tool parameters",
            properties: [
                "todos": .array(
                    description: "Task items to write. Omit to read current list.",
                    items: .object(
                        description: "A todo item",
                        properties: [
                            "id": .string(description: "Unique item identifier"),
                            "content": .string(description: "Task description"),
                            "status": .enum(
                                description: "Current status",
                                values: ["pending", "in_progress", "completed", "cancelled"]
                            ),
                        ],
                        required: ["id", "content", "status"]
                    )
                ),
                "merge": .boolean(
                    description: "true: update existing items by id, add new ones. false (default): replace the entire list."
                ),
            ],
            required: []
        ),
        handler: { args in
            let store = TodoTool.store ?? TodoTool.fallbackStore
            var incoming: [TodoItem] = []
            if let raw = args["todos"] {
                // LLM sometimes sends todos as a JSON string instead of a list.
                if let asString = raw as? String {
                    guard let data = asString.data(using: .utf8),
                          let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                        return "Error: todos must be a list of objects, got unparseable string."
                    }
                    incoming = parsed.compactMap(Self.item)
                } else if let list = raw as? [[String: Any]] {
                    incoming = list.compactMap(Self.item)
                } else {
                    return "Error: todos must be a list of objects."
                }
            }
            let merge = args["merge"] as? Bool ?? false
            let result: [TodoItem]
            if args["todos"] != nil {
                result = await store.write(incoming, merge: merge)
            } else {
                result = await store.read()
            }
            return Self.render(result)
        },
        emoji: "📋"
    )

    static func item(_ dict: [String: Any]) -> TodoItem? {
        guard let id = dict["id"] as? String,
              let content = dict["content"] as? String,
              let status = dict["status"] as? String else { return nil }
        return TodoStore.validate(TodoItem(id: id, content: content, status: status))
    }

    /// Reference-shaped result: JSON with the full list and a summary.
    static func render(_ items: [TodoItem]) -> String {
        var counts: [String: Int] = [:]
        for s in TodoStore.validStatuses { counts[s] = 0 }
        for item in items { counts[item.status, default: 0] += 1 }
        let summary: [String: Any] = [
            "total": items.count,
            "pending": counts["pending"] ?? 0,
            "in_progress": counts["in_progress"] ?? 0,
            "completed": counts["completed"] ?? 0,
            "cancelled": counts["cancelled"] ?? 0,
        ]
        let payload: [String: Any] = [
            "todos": items.map { ["id": $0.id, "content": $0.content, "status": $0.status] },
            "summary": summary,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "Error: could not serialize todo list."
        }
        return json
    }
}
