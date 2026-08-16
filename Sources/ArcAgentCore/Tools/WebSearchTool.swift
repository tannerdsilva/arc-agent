import Foundation
import AsyncHTTPClient
import NIO

/// The `web_search` tool: searches the web using a configurable search API.
///
/// Uses AsyncHTTPClient for non-blocking HTTP requests. The search endpoint
/// is configured via the agent's config (defaults to a SearXNG instance or
/// a configurable search API).
///
/// ## Parameters
/// - `query`: The search query.
/// - `limit`: (Optional) Max results to return. Default 5.
///
/// ## Returns
/// A formatted list of search results with titles, URLs, and descriptions.
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
        requiresEnv: ["SEARCH_API_KEY"],
        emoji: "🔍"
    )

    // MARK: - Handler

    private static func search(query: String, limit: Int) async throws -> String {
        let config = SearchConfig.current

        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { Task { try? await httpClient.shutdown() } }

        var urlComponents = URLComponents(string: config.endpoint)!
        urlComponents.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "format", value: "json"),
        ]

        var request = HTTPClientRequest(url: urlComponents.url!.absoluteString)
        request.method = .GET
        if let apiKey = config.apiKey {
            request.headers.add(name: "Authorization", value: "Bearer \(apiKey)")
        }

        let response = try await httpClient.execute(request, timeout: .seconds(30))
        let body = try await response.body.collect(upTo: 1_000_000)
        let data = Data(buffer: body)

        // Try to parse as JSON
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8) ?? "No response body"
        }

        // Format results
        if let results = json["results"] as? [[String: Any]] {
            var output: [String] = []
            for (i, result) in results.prefix(limit).enumerated() {
                let title = result["title"] as? String ?? "Untitled"
                let url = result["url"] as? String ?? ""
                let description = result["description"] as? String ?? result["content"] as? String ?? ""
                output.append("\(i + 1). \(title)")
                output.append("   \(url)")
                if !description.isEmpty {
                    output.append("   \(description)")
                }
                output.append("")
            }
            return output.joined(separator: "\n").trimmingCharacters(in: .newlines)
        }

        // Fallback: return raw JSON
        return String(data: try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]), encoding: .utf8) ?? "Empty response"
    }

    // MARK: - Helpers

    private static func required<T>(_ args: [String: Any], key: String) throws -> T {
        guard let value = args[key] as? T else {
            throw ToolError.missingParameter(key)
        }
        return value
    }
}

// MARK: - Configuration

/// Configuration for the web search tool.
public struct SearchConfig: Sendable {
    /// The search API endpoint URL.
    public let endpoint: String
    /// Optional API key for authenticated search endpoints.
    public let apiKey: String?

    /// The current configuration, resolved from environment or defaults.
    public static var current: SearchConfig {
        SearchConfig(
            endpoint: ProcessInfo.processInfo.environment["SEARCH_ENDPOINT"]
                ?? "https://search.example.com/search",
            apiKey: ProcessInfo.processInfo.environment["SEARCH_API_KEY"]
        )
    }
}
