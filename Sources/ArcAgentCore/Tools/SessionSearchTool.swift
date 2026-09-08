import Foundation

/// Search past conversation sessions for keywords.
///
/// Reads through the agent's configured ``SessionStore`` (wired statically at
/// startup, mirroring ``MemoryTool``), so the model can recall what was said
/// in earlier sessions — the counterpart to session-history restore.
public struct SessionSearchTool: Sendable {
    /// The session store to search. Wired by the agent at startup.
    public static var store: (any SessionStore)?

    public static let entry = ToolEntry(
        name: "session_search",
        toolset: "core",
        description: "Search past conversation sessions for a keyword or phrase. Returns matching session IDs, titles, and message excerpts.",
        schema: .object(properties: [
            "query": .string(description: "Keyword or phrase to search for"),
            "limit": .integer(description: "Max sessions to scan (default 50)", default: 50),
        ], required: ["query"]),
        handler: { args in
            guard let store = SessionSearchTool.store else {
                return "Error: session search unavailable (no session store wired)."
            }
            let query = (args["query"] as? String ?? "").lowercased()
            guard !query.isEmpty else { return "Error: 'query' is required." }
            let limit = max(1, min(args["limit"] as? Int ?? 50, 500))

            let sessions = (try? await store.list(limit: limit)) ?? []
            var results: [String] = []
            for session in sessions {
                let matches = session.messages.filter { ($0.content ?? "").lowercased().contains(query) }
                guard !matches.isEmpty else { continue }
                let title = session.title ?? "(untitled)"
                var lines = "Session \(session.id.prefix(8)) — \(title) (\(matches.count) match(es)):"
                for m in matches.prefix(3) {
                    let snippet = (m.content ?? "").replacingOccurrences(of: "\n", with: " ")
                    let preview = String(snippet.prefix(200))
                    lines += "\n  [\(m.role.rawValue)] \(preview)"
                }
                results.append(lines)
            }
            return results.isEmpty
                ? "No sessions matched '\(query)'."
                : results.joined(separator: "\n\n")
        }
    )
}
