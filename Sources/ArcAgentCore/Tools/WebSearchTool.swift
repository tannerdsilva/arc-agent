import Foundation

/// The `web_search` tool: searches the web via the configured search backend
/// (Hermes `web.search_backend` semantics — pluggable provider registry).
///
/// Providers: SearXNG (legacy default), Brave, Tavily, DuckDuckGo (key-less
/// fallback). The active engine is selected by config; a missing key or
/// unavailable engine degrades with a Hermes-style error rather than
/// producing nothing.
public enum WebSearchTool {

    /// The ``ToolEntry`` for this tool.
    public static let entry = ToolEntry(
        name: "web_search",
        toolset: "web",
        description: "Search the web for information. Returns up to 5 results "
            + "with titles, URLs, and descriptions.",
        schema: .object(
            description: "Search the web",
            properties: [
                "query": .string(description: "The search query"),
                "limit": .integer(description: "Maximum number of results", default: 5),
            ],
            required: ["query"]
        ),
        handler: { args in
            let query: String = try Self.required(args, key: "query")
            let limit: Int = (args["limit"] as? Int) ?? 5
            return try await Self.search(query: query, limit: limit)
        },
        emoji: "🔍"
    )

    // MARK: - Handler

    private static func search(query: String, limit: Int) async throws -> String {
        await BuiltinSearchProviders.registerIntoShared()
        let results = try await SearchRegistry.shared.perform(query: query, limit: limit)
        guard !results.isEmpty else {
            return "No results found."
        }
        var lines = ["Search results for \"\(query)\":"]
        for result in results {
            lines.append("\(result.position + 1). \(result.title)")
            if !result.description.isEmpty {
                lines.append("   \(result.description)")
            }
            lines.append("   \(result.url)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func required(_ args: [String: Any], key: String) throws -> String {
        guard let value = args[key] as? String, !value.isEmpty else {
            throw ToolError.missingParameter(key)
        }
        return value
    }
}
