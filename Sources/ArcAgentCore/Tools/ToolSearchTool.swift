import Foundation

// MARK: - tool_search (reference `tools/tool_search.py` catalog bridge)

/// The `tool_search` tool: discover tools in the current catalog by keyword.
///
/// reference keeps a deferred-tool catalog (BM25-scored) so the model can find
/// capabilities whose schemas were held out of the prompt. Arc always loads
/// its full static toolset, so this tool serves the same purpose — a
/// discoverable, keyword-searchable index of the toolset the agent has —
/// and returns the same *shape*: a grouped name + short-description listing.
public enum ToolSearchTool {

    /// The registry searched by the handler. Wired by the agent at startup;
    /// when nil the handler falls back to ``ArcAgentCore/buildDefaultRegistry()``.
    public nonisolated(unsafe) static var registry: (any ToolRegistry)?

    static let toolsets = "tools"
    static let forms = ["listing", "names", "mixed"]

    public static let entry = ToolEntry(
        name: "tool_search",
        toolset: "tools",
        description: "Search the available tool catalog for a keyword/phrase, or list all tools. "
            + "Returns tool names with short descriptions so you can pick the right tool. "
            + "Parameters: query (omit for the full listing), limit (default 5), form "
            + "('listing' = name + short description, 'names' = bare names, 'mixed').",
        schema: .object(
            description: "Tool search parameters",
            properties: [
                "query": .string(description: "Keyword/phrase to search for (omit to list)"),
                "limit": .integer(description: "Max results (default 5)"),
                "form": .string(description: "Output form: listing | names | mixed (default listing)"),
            ],
            required: []
        ),
        handler: { args in
            let query = ((args["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let limit = (args["limit"] as? Int) ?? 5
            let form = (args["form"] as? String) ?? "listing"
            guard forms.contains(form) else {
                return "Error: invalid form '\(form)'. Valid forms: \(forms.joined(separator: ", "))"
            }
            guard let registry = resolveRegistry() else {
                return "Error: tool registry is unavailable."
            }
            let tools = registry.allTools
            let catalog: [CatalogEntry] = tools.map {
                CatalogEntry(name: $0.name, description: $0.description, toolset: $0.toolset)
            }
            let results: [CatalogEntry]
            if query.isEmpty {
                results = catalog
            } else {
                results = Self.search(catalog, query: query, limit: max(1, limit))
            }
            return Self.render(results, form: form, total: catalog.count, query: query)
        },
        emoji: "🔎"
    )

    static func resolveRegistry() -> (any ToolRegistry)? {
        if let registry { return registry }
        return try? ArcAgentCore.buildDefaultRegistry()
    }

    // MARK: - Catalog + search

    struct CatalogEntry {
        let name: String
        let description: String
        let toolset: String
    }

    /// Token-overlap scoring (reference BM25-order-of-magnitude: name terms weigh
    /// more than description terms; longer matches rank higher).
    static func search(_ catalog: [CatalogEntry], query: String, limit: Int) -> [CatalogEntry] {
        let terms = tokenize(query)
        guard !terms.isEmpty else { return Array(catalog.prefix(limit)) }
        let scored = catalog.map { entry -> (CatalogEntry, Int) in
            var score = 0
            let nameTokens = tokenize(entry.name)
            let descTokens = tokenize(entry.description)
            let nameSet = Set(nameTokens)
            let descSet = Set(descTokens)
            for term in terms {
                if nameSet.contains(term) { score += 4 }
                if descSet.contains(term) { score += 1 }
            }
            // Full substring match on name is a strong signal too.
            if entry.name.lowercased().contains(query.lowercased()) { score += 6 }
            return (entry, score)
        }
        let filtered = scored.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        return Array(filtered.prefix(limit)).map { $0.0 }
    }

    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.count >= 2 }
            .map(String.init)
    }

    static func shortDesc(_ description: String, maxChars: Int = 60) -> String {
        let text = description.split(separator: " ").joined(separator: " ")
        guard text.count > maxChars else { return text }
        return String(text.prefix(maxChars)) + "…"
    }

    static func render(_ results: [CatalogEntry], form: String, total: Int, query: String) -> String {
        if results.isEmpty {
            return "No tools match\(query.isEmpty ? "" : " '\(query)'"). Use tool_search without a query to list everything."
        }
        switch form {
        case "names":
            return results.map { $0.name }.joined(separator: ", ")
        case "mixed":
            let lines = results.map { "\($0.name): \(shortDesc($0.description))" }
            return lines.joined(separator: "\n")
        default: // listing — grouped by toolset, reference style
            var groups: [(String, [CatalogEntry])] = []
            for entry in results {
                if let idx = groups.firstIndex(where: { $0.0 == entry.toolset }) {
                    groups[idx].1.append(entry)
                } else {
                    groups.append((entry.toolset, [entry]))
                }
            }
            var lines: [String] = []
            if !query.isEmpty {
                lines.append("Matching tools (\(results.count) shown of \(total) catalogued):")
                lines.append("")
            } else {
                lines.append("Tool catalog (\(total) tools):")
                lines.append("")
            }
            for (toolset, entries) in groups.sorted(by: { $0.0 < $1.0 }) {
                lines.append("📦 \(toolset)")
                for entry in entries.sorted(by: { $0.name < $1.name }) {
                    lines.append("  \(entry.name) — \(shortDesc(entry.description))")
                }
                lines.append("")
            }
            return lines.joined(separator: "\n")
        }
    }
}
