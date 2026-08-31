import Foundation
import AsyncHTTPClient

/// The `web_extract` tool: fetches a URL and returns its content as text.
///
/// Uses AsyncHTTPClient for non-blocking HTTP requests. Returns the raw page
/// content. For HTML pages, basic text extraction is attempted.
///
/// ## Parameters
/// - `url`: The URL to fetch.
/// - `char_limit`: (Optional) Max characters to return. Default 15000.
///
/// ## Returns
/// The page content as text, truncated to char_limit if necessary.
public enum WebExtractTool {

    /// The ``ToolEntry`` for this tool.
    public static let entry = ToolEntry(
        name: "web_extract",
        toolset: "web",
        description: "Fetch a URL and return its content as text. "
            + "Works with HTML pages, plain text, and JSON endpoints.",
        schema: .object(
            description: "Extract content from a URL",
            properties: [
                "url": .string(description: "The URL to fetch"),
                "char_limit": .integer(description: "Max characters to return", default: 15000),
            ],
            required: ["url"]
        ),
        handler: { args in
            let url: String = try Self.required(args, key: "url")
            let charLimit: Int = (args["char_limit"] as? Int) ?? 15000
            return try await Self.extract(url: url, charLimit: charLimit)
        },
        emoji: "🌐"
    )

    // MARK: - Handler

    private static func extract(url urlString: String, charLimit: Int) async throws -> String {
        guard let url = URL(string: urlString) else {
            return "Error: Invalid URL '\(urlString)'."
        }

        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { Task { try? await httpClient.shutdown() } }

        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .GET
        request.headers.add(name: "User-Agent", value: "ArcAgent/0.1")

        let response = try await httpClient.execute(request, timeout: .seconds(30))
        let body = try await response.body.collect(upTo: 1_000_000)
        let data = Data(buffer: body)

        guard var text = String(data: data, encoding: .utf8) else {
            return "Error: Response is not valid UTF-8 text."
        }

        // Basic HTML tag stripping for a cleaner read
        if urlString.contains(".html") || text.contains("<!DOCTYPE") || text.contains("<html") {
            text = stripHTML(text)
        }

        // Truncate if needed
        if text.count > charLimit {
            let head = text.prefix(charLimit / 2)
            let tail = text.suffix(charLimit / 2)
            return """
            \(head)
            
            ... [TRUNCATED: showing \(charLimit) of \(text.count) characters] ...
            
            \(tail)
            """
        }

        return text
    }

    // MARK: - HTML Stripping

    /// Basic HTML tag and script/style removal.
    private static func stripHTML(_ html: String) -> String {
        var text = html

        // Remove script and style blocks
        if let scriptRange = text.range(of: "<script", options: .caseInsensitive) {
            let remaining = text[scriptRange.lowerBound...]
            if let endRange = remaining.range(of: "</script>", options: .caseInsensitive) {
                text.removeSubrange(scriptRange.lowerBound...endRange.upperBound)
            }
        }
        if let styleRange = text.range(of: "<style", options: .caseInsensitive) {
            let remaining = text[styleRange.lowerBound...]
            if let endRange = remaining.range(of: "</style>", options: .caseInsensitive) {
                text.removeSubrange(styleRange.lowerBound...endRange.upperBound)
            }
        }

        // Remove HTML tags
        var result = ""
        var inTag = false
        for char in text {
            if char == "<" { inTag = true; continue }
            if char == ">" { inTag = false; continue }
            if !inTag { result.append(char) }
        }

        // Collapse whitespace
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\n\\s*\\n", with: "\n\n", options: .regularExpression)

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private static func required<T>(_ args: [String: Any], key: String) throws -> T {
        guard let value = args[key] as? T else {
            throw ToolError.missingParameter(key)
        }
        return value
    }
}
