import Foundation
import AsyncHTTPClient
import NIO

/// Built-in web search backends (reference `plugins/web/*`, in-tree).
///
/// Banner: the pluggable engines that make `web.search_backend` meaningful —
/// SearXNG (self-hosted JSON API), Brave (X-Subscription-Token),
/// Tavily (POST API), and DuckDuckGo (key-less HTML). Each normalizes to the
/// reference response-shape contract. Parsers are exposed as internal statics so
/// they can be unit-tested without network access.

// MARK: - SearXNG (legacy default, compatible with the old single-API path)

public struct SearXNGSearchProvider: SearchProvider {
    public let name = "searxng"
    public let displayName = "SearXNG (self-hosted)"
    public let endpoint: String
    public let apiKey: String?

    public init(endpoint: String, apiKey: String? = nil) {
        self.endpoint = endpoint
        self.apiKey = apiKey
    }

    public func isAvailable() -> Bool {
        !endpoint.isEmpty
    }

    public func search(query: String, limit: Int) async throws -> [SearchResult] {
        var components = URLComponents(string: endpoint) ?? URLComponents()
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else { throw SearchError.badResponse("invalid endpoint") }
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .GET
        if let apiKey {
            request.headers.add(name: "Authorization", value: "Bearer \(apiKey)")
        }
        let body = try await HTTPTransport.execute(request)
        return try Self.parseSearchJSON(body, endpoint: endpoint)
    }

    /// Normalize a SearXNG JSON response (also used by tests).
    internal static func parseSearchJSON(_ body: Data, endpoint: String) throws -> [SearchResult] {
        let json = try JSONSerialization.jsonObject(with: body)
        guard let root = json as? [String: Any],
              let results = root["results"] as? [[String: Any]] else {
            throw SearchError.badResponse("missing 'results' array")
        }
        var out: [SearchResult] = []
        for item in results {
            let url = (item["url"] as? String) ?? ""
            guard !url.isEmpty else { continue }
            out.append(SearchResult(
                title: (item["title"] as? String) ?? "",
                url: url,
                description: (item["content"] as? String) ?? (item["description"] as? String) ?? "",
                position: out.count
            ))
        }
        return out
    }
}

// MARK: - Brave

public struct BraveSearchProvider: SearchProvider {
    public let name = "brave"
    public let displayName = "Brave Search"
    public let endpoint: String
    public let apiKey: String

    public init(apiKey: String, endpoint: String = "https://api.search.brave.com/res/v1/web/search") {
        self.apiKey = apiKey
        self.endpoint = endpoint
    }

    public func isAvailable() -> Bool {
        !apiKey.isEmpty
    }

    public func search(query: String, limit: Int) async throws -> [SearchResult] {
        var components = URLComponents(string: endpoint) ?? URLComponents()
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(limit)),
        ]
        guard let url = components.url else { throw SearchError.badResponse("invalid endpoint") }
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .GET
        request.headers.add(name: "X-Subscription-Token", value: apiKey)
        request.headers.add(name: "Accept", value: "application/json")
        let body = try await HTTPTransport.execute(request)
        return try Self.parseSearchJSON(body)
    }

    internal static func parseSearchJSON(_ body: Data) throws -> [SearchResult] {
        let json = try JSONSerialization.jsonObject(with: body)
        guard let root = json as? [String: Any],
              let web = root["web"] as? [String: Any],
              let results = web["results"] as? [[String: Any]] else {
            throw SearchError.badResponse("missing web.results")
        }
        var out: [SearchResult] = []
        for item in results {
            let url = (item["url"] as? String) ?? ""
            guard !url.isEmpty else { continue }
            out.append(SearchResult(
                title: (item["title"] as? String) ?? "",
                url: url,
                description: (item["description"] as? String) ?? "",
                position: out.count
            ))
        }
        return out
    }
}

// MARK: - Tavily

public struct TavilySearchProvider: SearchProvider {
    public let name = "tavily"
    public let displayName = "Tavily"
    public let apiKey: String

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    public func isAvailable() -> Bool {
        !apiKey.isEmpty
    }

    public func search(query: String, limit: Int) async throws -> [SearchResult] {
        let payload: [String: Any] = [
            "api_key": apiKey,
            "query": query,
            "max_results": limit,
            "include_answer": false,
        ]
        var request = HTTPClientRequest(url: "https://api.tavily.com/search")
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/json")
        request.body = .bytes(try JSONSerialization.data(withJSONObject: payload))
        let body = try await HTTPTransport.execute(request)
        return try Self.parseSearchJSON(body)
    }

    internal static func parseSearchJSON(_ body: Data) throws -> [SearchResult] {
        let json = try JSONSerialization.jsonObject(with: body)
        guard let root = json as? [String: Any],
              let results = root["results"] as? [[String: Any]] else {
            throw SearchError.badResponse("missing 'results'")
        }
        var out: [SearchResult] = []
        for item in results {
            let url = (item["url"] as? String) ?? ""
            guard !url.isEmpty else { continue }
            out.append(SearchResult(
                title: (item["title"] as? String) ?? "",
                url: url,
                description: (item["content"] as? String) ?? "",
                position: out.count
            ))
        }
        return out
    }
}

// MARK: - DuckDuckGo (key-less)

public struct DuckDuckGoSearchProvider: SearchProvider {
    public let name = "ddgs"
    public let displayName = "DuckDuckGo (key-less)"
    public let endpoint: String

    public init(endpoint: String = "https://html.duckduckgo.com/html/") {
        self.endpoint = endpoint
    }

    public func isAvailable() -> Bool {
        true
    }

    public func search(query: String, limit: Int) async throws -> [SearchResult] {
        var components = URLComponents(string: endpoint) ?? URLComponents()
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { throw SearchError.badResponse("invalid endpoint") }
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .GET
        request.headers.add(name: "User-Agent", value: "arc-agent/0.1 (web search)")
        let body = try await HTTPTransport.execute(request)
        return try Self.parseSearchHTML(body, limit: limit)
    }

    /// Best-effort parse of `html.duckduckgo.com/html/` results.
    internal static func parseSearchHTML(_ body: Data, limit: Int) throws -> [SearchResult] {
        guard let html = String(data: body, encoding: .utf8) else {
            throw SearchError.badResponse("non-UTF8 response")
        }
        var results: [SearchResult] = []
        let linkPattern = #"<a[^>]+class="result__a"[^>]+href="([^"]+)"[^>]*>(.*?)</a>"#
        let snippetPattern = #"<a[^>]+class="result__snippet"[^>]*>(.*?)</a>"#
        let escapePattern = #"<[^>]+>"#
        let links = matches(html, pattern: linkPattern)
        let snippets = matches(html, pattern: snippetPattern)
        for (idx, link) in links.enumerated() where results.count < limit {
            var url = link.group(1) ?? ""
            if url.hasPrefix("//") { url = "https:" + url }
            if let uddg = url.range(of: "uddg=") {
                let encoded = String(url[uddg.upperBound...])
                url = encoded.removingPercentEncoding ?? encoded
            }
            let rawTitle = link.group(2) ?? ""
            let title = strip(html: rawTitle, escape: escapePattern)
            let desc = idx < snippets.count ? strip(html: snippets[idx].group(1) ?? "", escape: escapePattern) : ""
            guard !url.isEmpty, !title.isEmpty else { continue }
            results.append(SearchResult(title: title, url: url, description: desc, position: results.count))
        }
        return results
    }

    // MARK: HTML helpers

    private struct Match {
        let groups: [String?]
        func group(_ i: Int) -> String? { i < groups.count ? groups[i] : nil }
    }

    private static func matches(_ text: String, pattern: String) -> [Match] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { m in
            let groups = (0..<m.numberOfRanges).map { i -> String? in
                guard let r = Range(m.range(at: i), in: text) else { return nil }
                return String(text[r])
            }
            return Match(groups: groups)
        }
    }

    private static func strip(html: String, escape: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: escape) else { return html }
        var s = html
        let range = NSRange(s.startIndex..., in: s)
        s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
        return s
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - HTTP transport (one-shot clients; torn down per call)

enum HTTPTransport {
    static func execute(_ request: HTTPClientRequest) async throws -> Data {
        let client = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { Task { try? await client.shutdown() } }
        do {
            let response = try await client.execute(request, timeout: .seconds(30))
            let status = response.status.code
            let body = try await response.body.collect(upTo: 2_000_000)
            let data = Data(buffer: body)
            guard status == 200 else {
                throw SearchError.http(Int(status), String(decoding: data, as: UTF8.self))
            }
            return data
        } catch let e as SearchError {
            throw e
        } catch {
            throw SearchError.badResponse(error.localizedDescription)
        }
    }
}

// MARK: - Built-in registration

public enum BuiltinSearchProviders {
    /// All built-in providers, in reference-banner order (SearXNG first as the
    /// legacy default; ddgs last as the key-less fallback).
    public static func all() -> [SearchProvider] {
        var providers: [SearchProvider] = []
        let searxEndpoint = SearchEnv.get("SEARCH_ENDPOINT")
        let searxKey = SearchEnv.get("SEARCH_API_KEY")
        if !searxEndpoint.isEmpty {
            providers.append(SearXNGSearchProvider(endpoint: searxEndpoint, apiKey: searxKey.isEmpty ? nil : searxKey))
        }
        let braveKey = SearchEnv.get("BRAVE_API_KEY")
        if !braveKey.isEmpty {
            providers.append(BraveSearchProvider(apiKey: braveKey))
        }
        let tavilyKey = SearchEnv.get("TAVILY_API_KEY")
        if !tavilyKey.isEmpty {
            providers.append(TavilySearchProvider(apiKey: tavilyKey))
        }
        // Reference `plugins/web/firecrawl` + `plugins/web/exa`
        // (search + extract backends, legacy-preference order first).
        let firecrawlKey = SearchEnv.get("FIRECRAWL_API_KEY")
        if !firecrawlKey.isEmpty {
            providers.append(FirecrawlProvider(apiKey: firecrawlKey))
        }
        let exaKey = SearchEnv.get("EXA_API_KEY")
        if !exaKey.isEmpty {
            providers.append(ExaSearchProvider(apiKey: exaKey))
        }
        providers.append(DuckDuckGoSearchProvider())
        return providers
    }

    /// Register built-ins into the shared registry (idempotent).
    public static func registerIntoShared() async {
        for provider in all() {
            await SearchRegistry.shared.register(provider)
        }
    }
}
