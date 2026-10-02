import Foundation
import AsyncHTTPClient
import CryptoKit

/// The `web_extract` tool (reference `web_extract_tool`): clean page content
/// via the configured extract backend (Firecrawl/Exa natively, fetch+strip
/// otherwise), per-URL, with char_limit head+tail truncation, full text
/// cached under `~/.arc/cache/web/`, inline base64 images replaced with
/// `[IMAGE: alt]`, and URLs checked for embedded secrets before fetching.
public enum WebExtractTool {

    public static let entry = ToolEntry(
        name: "web_extract",
        toolset: "web",
        description: "Extract content from web pages (URLs) as clean markdown/text. "
            + "Accepts a single URL or a list of URLs; each page is returned with "
            + "content, truncated to char_limit with full text cached for read_file.",
        schema: .object(
            description: "Extract content from URLs",
            properties: [
                "urls": .array(items: .string(description: "URL(s) to extract (or use `url` for one)")),
                "url": .string(description: "Single URL to extract (alternative to `urls`)"),
                "format": .string(description: "Output format: markdown or html (optional)"),
                "char_limit": .integer(description: "Max characters per page to return (default 15000)"),
            ],
            required: []
        ),
        handler: { args in
            let urls = try Self.collectURLs(args)
            let format = args["format"] as? String
            let charLimit: Int = (args["char_limit"] as? Int) ?? 15000
            return try await Self.extract(urls: urls, format: format, charLimit: charLimit)
        },
        emoji: "🌐"
    )

    // MARK: - Handler

    static func collectURLs(_ args: [String: Any]) throws -> [String] {
        if let urls = args["urls"] as? [String], !urls.isEmpty { return urls }
        if let url = args["url"] as? String, !url.isEmpty { return [url] }
        // Search-result-object list shape (reference accepts objects with
        // `url`/`href` fields).
        if let objects = args["urls"] as? [[String: Any]] {
            let extracted = objects.compactMap { ($0["url"] as? String) ?? ($0["href"] as? String) }
            if !extracted.isEmpty { return extracted }
        }
        throw ToolError.missingParameter("urls")
    }

    /// Embedded-secret check (reference: URLs are checked for secrets before
    /// fetching) — env-var shaped substrings are refused.
    static func containsEmbeddedSecret(_ url: String) -> Bool {
        guard let components = URLComponents(string: url) else { return false }
        let haystack = (components.query ?? "").lowercased()
        for key in ["api_key", "apikey", "access_token", "token=", "secret", "password", "auth="] where haystack.contains(key) {
            return true
        }
        return false
    }

    static func replaceInlineBase64(_ content: String) -> String {
        // `data:image/png;base64,....` → `[IMAGE: alt]` (reference: inline
        // base64 images replaced with placeholders).
        guard let regex = try? NSRegularExpression(
            pattern: "data:image/[a-z+]+;base64,[A-Za-z0-9+/=]+",
            options: [.caseInsensitive]
        ) else { return content }
        let range = NSRange(content.startIndex..., in: content)
        return regex.stringByReplacingMatches(
            in: content, range: range,
            withTemplate: "[IMAGE: inline base64]"
        )
    }

    private static func extract(urls: [String], format: String?, charLimit: Int) async throws -> String {
        // Resolve the extract backend (reference `_resolve_provider`).
        let config = loadConfig()
        let configured = config.web.extractBackend ?? config.web.backend
        let extractor = await SearchRegistry.shared.resolveExtractor(configured: configured)

        var output: [String] = []
        for url in urls {
            guard !containsEmbeddedSecret(url) else {
                output.append("### \(url)\nError: URL contains embedded credentials; refused to fetch.\n")
                continue
            }
            let page: ExtractedPage
            if let (provider, _) = extractor {
                do {
                    let pages = try await provider.extract(urls: [url], format: format)
                    page = pages.first ?? ExtractedPage(url: url, content: "", format: "text")
                } catch {
                    output.append("### \(url)\nError: \(error)\n")
                    continue
                }
            } else {
                page = try await fallbackExtract(url: url, format: format)
            }
            var content = replaceInlineBase64(page.content)
            if format == "html" && page.format != "html" {
                content = stripHTML(content)
            }
            // Truncate with cache (reference: full text stored under cache/web).
            if content.count > charLimit {
                let cachePath = writeCache(content, url: url)
                let head = content.prefix(charLimit / 2)
                let tail = content.suffix(charLimit / 2)
                output.append("""
                ### \(url)
                \(head)

                ... [TRUNCATED: showing \(charLimit) of \(content.count) characters] ...

                Full text: read_file \(cachePath)

                \(tail)
                """)
            } else {
                output.append("### \(url)\n\(content)")
            }
        }
        return output.joined(separator: "\n\n")
    }

    private static func writeCache(_ content: String, url: String) -> String {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arc/cache/web", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = dir.appendingPathComponent("\(String(digest.prefix(16))).md")
        try? content.write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    /// Backend-less fallback: fetch + strip (previous behavior, reference
    /// `web_extract` when no extract-capable provider is available).
    private static func fallbackExtract(url urlString: String, format: String?) async throws -> ExtractedPage {
        guard let url = URL(string: urlString) else {
            throw SearchError.badResponse("invalid URL '\(urlString)'")
        }
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { Task { try? await httpClient.shutdown() } }
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .GET
        request.headers.add(name: "User-Agent", value: "ArcAgent/0.1")
        let response = try await httpClient.execute(request, timeout: .seconds(30))
        let data = try await response.body.collect(upTo: 1_000_000)
        let body = String(data: Data(buffer: data), encoding: .utf8) ?? ""
        if urlString.contains(".html") || body.contains("<!DOCTYPE") || body.contains("<html") {
            return ExtractedPage(url: urlString, content: stripHTML(body), format: "text")
        }
        return ExtractedPage(url: urlString, content: body, format: "text")
    }

    // MARK: - HTML stripping

    static func stripHTML(_ html: String) -> String {
        var text = html
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
        var result = ""
        var inTag = false
        for char in text {
            if char == "<" { inTag = true; continue }
            if char == ">" { inTag = false; continue }
            if !inTag { result.append(char) }
        }
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\n\s*\n"#, with: "\n\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
