import ArcToolKit
import Foundation

/// The `memory` tool: save durable facts to persistent memory (arc parity).
///
/// reference-shaped schema: `action` (add/replace/remove, single-op shape),
/// `target` (memory/user), `content`, `old_text`, and `operations` (batch
/// shape — preferred; applied atomically against the final char budget).
/// Reads happen via system-prompt injection, not the tool — matching reference.
///
/// ## Scope
///
/// The provider is captured at construction, one per agent, resolved by the
/// construction site that owns the profile (`buildRegistry(context:memory:)`).
/// The tool used to read a process-global `MemoryTool.provider` that
/// `ArcAgent` overwrote on every start, so two profiles in one process wrote
/// one file — the addressing defect pinned by
/// `memory tool and profile_edit share one document`.
///
/// Writes are gated by the `ToolGrant` in the caller's ``ToolContext``: the
/// same value `profile_edit` refuses with, so the two tools can no longer
/// disagree about which profile's document they are addressing or whether it
/// is open.
struct MemoryTool {

    /// Build the tool for one caller.
    ///
    /// - Parameters:
    ///   - context: the calling identity — its `grant` decides whether the
    ///     target document may be written.
    ///   - memory: the provider this agent's memory lives in. It is the same
    ///     store the prompt's memory block is read from, so a write the model
    ///     makes here is the write it reads back next turn.
    static func entry(context: ToolContext, memory: any MemoryProvider) -> ToolEntry {
        ToolEntry(
            name: "memory",
            toolset: "core",
            description: "Save durable facts to persistent memory that survive across sessions. Memory is "
                + "injected into every future turn, so keep entries compact and high-signal.\n\n"
                + "HOW: make ALL your changes in ONE call via an 'operations' array (each item: "
                + "{action, content?, old_text?}). The batch applies atomically and the char limit is "
                + "checked only on the FINAL result — so a single call can remove/replace stale entries "
                + "to free room AND add new ones, even when an add alone would overflow. The response "
                + "reports current/limit chars and confirms completion; one batch call finishes the "
                + "update, so don't repeat it. Use the bare action/content/old_text fields only for a "
                + "single lone change.\n\n"
                + "WHEN: save proactively when the user states a preference, correction, or personal "
                + "detail, or you learn a stable fact about their environment, conventions, or workflow. "
                + "Priority: user preferences & corrections > environment facts > procedures. The best "
                + "memory stops the user repeating themselves.\n\n"
                + "IF FULL: an add is rejected with the current entries shown. Reissue as ONE batch that "
                + "removes or shortens enough stale entries and adds the new one together.\n\n"
                + "TARGETS: 'user' = who the user is (name, role, preferences, style). 'memory' = your "
                + "notes (environment, conventions, tool quirks, lessons).\n\n"
                + "SKIP: trivial/obvious info, easily re-discovered facts, raw data dumps, task progress, "
                + "completed-work logs, temporary TODO state (use session_search for those). Reusable "
                + "procedures belong in a skill, not memory.",
            schema: .object(
                description: "Memory operation parameters",
                properties: [
                    "action": .enum(
                        description: "The action to perform (single-op shape). Omit when using 'operations'.",
                        values: ["add", "replace", "remove"]
                    ),
                    "target": .enum(
                        description: "Which memory store: 'memory' for personal notes, 'user' for user profile.",
                        values: ["memory", "user"]
                    ),
                    "content": .string(
                        description: "The entry content. Required for 'add' and 'replace' (single-op shape)."
                    ),
                    "old_text": .string(
                        description: "REQUIRED for 'replace' and 'remove' (single-op shape): a short unique substring identifying the existing entry to modify. Omit only for 'add'."
                    ),
                    "operations": .array(
                        description: "Batch shape: a list of operations applied atomically in one call "
                            + "against the final char budget. Preferred when making multiple changes "
                            + "or consolidating to make room. Each item is {action, content?, old_text?}.",
                        items: .object(
                            description: "A single memory operation",
                            properties: [
                                "action": .enum(
                                    description: "The operation to apply.",
                                    values: ["add", "replace", "remove"]
                                ),
                                "content": .string(description: "Entry content for add/replace."),
                                "old_text": .string(description: "Substring identifying the entry for replace/remove."),
                            ],
                            required: ["action"]
                        )
                    ),
                ],
                required: ["target"]
            ),
            handler: { args in
                let target = args["target"] as? String ?? "memory"
                let store = MemoryStore(provider: memory)

                // The document this target addresses — the same mapping
                // `MemoryStore` uses, so the gate cannot be asked about one
                // document while the write lands in another. The grant is
                // immutable, so one read covers every branch below.
                let document: ProfileFile = target == "user" ? .user : .memory
                let refusal = context.grant.refusal(for: document)

                let action = args["action"] as? String ?? ""
                let content = args["content"] as? String
                let oldText = args["old_text"] as? String

                // Batch shape wins when present (reference precedence).
                let operations = args["operations"] as? [[String: Any]]
                if let operations, !operations.isEmpty {
                    if let refusal {
                        return "Error: " + refusal
                    }
                    let result = try await store.applyBatch(target, operations)
                    return MemoryTool.render(result)
                }

                guard !action.isEmpty else {
                    return "Error: 'action' is required (use 'operations' for multi-change batches)."
                }
                if let refusal {
                    return "Error: " + refusal
                }

                let result: [String: Any]
                switch action {
                case "add":
                    result = try await store.add(target, content ?? "")
                case "replace":
                    result = try await store.replace(target, oldText ?? "", content ?? "")
                case "remove":
                    result = try await store.remove(target, oldText ?? "")
                default:
                    return "Error: Unknown action '\(action)'. Use add, replace, or remove."
                }
                return MemoryTool.render(result)
            },
            emoji: "🧠"
        )
    }

    /// Render the reference-shaped result dict as a tool-result string.
    private static func render(_ result: [String: Any]) -> String {
        if let error = result["error"] as? String {
            var out = "Error: \(error)"
            if let usage = result["usage"] as? String { out += "\nUsage: \(usage)" }
            if let entries = result["current_entries"] as? [String] {
                out += "\nCurrent entries: " + entries.joined(separator: " • ")
            }
            if let matches = result["matches"] as? [String] {
                out += "\nMatching entries: " + matches.joined(separator: " • ")
            }
            return out
        }
        var out = "\(result["message"] as? String ?? "OK")"
        if let usage = result["usage"] as? String { out += " (usage \(usage))" }
        if let count = result["entry_count"] as? Int { out += ". \(count) entr\(count == 1 ? "y" : "ies") total." }
        return out
    }
}
