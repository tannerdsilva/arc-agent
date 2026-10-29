import Foundation

/// Search past conversation sessions for keywords.
///
/// Reads through the ``SessionStore`` the surface was built with — the slot
/// the builder fills from its `sessions` parameter (GROUNDZERO slice 6
/// replaced the process-global pointer this tool used to read).
public struct SessionSearchTool: Sendable {

    /// The tool, bound to the slot naming the store it searches.
    public static func entry(
        store: ToolDependency<any SessionStore> = ToolDependency()
    ) -> ToolEntry {
        ToolEntry(
            name: "session_search",
            toolset: "core",
            description: "Search past conversation sessions for a keyword or phrase. Returns matching session IDs, titles, and message excerpts.",
            schema: .object(properties: [
                "query": .string(description: "Keyword or phrase to search for"),
                "limit": .integer(description: "Max sessions to scan (default 50)", default: 50),
            ], required: ["query"]),
            handler: { args in
                guard let store = store.get() else {
                    return "Error: session search unavailable (no session store wired)."
                }
                let query = (args["query"] as? String ?? "").lowercased()
                guard !query.isEmpty else { return "Error: 'query' is required." }
                let limit = max(1, min(args["limit"] as? Int ?? 50, 500))

                let sessions = (try? await store.list(limit: limit)) ?? []
                var results: [String] = []
                for summary in sessions {
                    // list() returns metadata-only summaries; materialize each
                    // session's messages before searching them.
                    guard let session = try? await store.get(id: summary.id) else { continue }
                    let matches = session.messages.filter { ($0.content ?? "").lowercased().contains(query) }
                    guard !matches.isEmpty else { continue }
                    let title = session.title ?? summary.title ?? "(untitled)"
                    var lines = "Session \(summary.id.prefix(8)) — \(title) (\(matches.count) match(es)):"
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
}
