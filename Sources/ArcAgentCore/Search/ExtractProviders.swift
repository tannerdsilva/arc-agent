import Foundation
import AsyncHTTPClient
import NIOCore
import CryptoKit

// MARK: - Web extraction (reference `plugins/web/{firecrawl,exa}/provider.py`)

/// Extracted page content (reference per-URL result item).
public struct ExtractedPage: Sendable, Equatable {
    public let url: String
    public let content: String
    public let format: String  // "markdown" | "html" | "text"
    public let error: String?

    public init(url: String, content: String, format: String, error: String? = nil) {
        self.url = url
        self.content = content
        self.format = format
        self.error = error
    }
}

/// Providers that can extract clean page content natively (reference
/// `supports_extract`).
public protocol ExtractProvider: Sendable {
    var name: String { get }
    /// Cheap availability check (env var present). No network.
    func isExtractAvailable() -> Bool
    /// Extract one or more URLs (reference per-URL results incl. failures).
    func extract(urls: [String], format: String?) async throws -> [ExtractedPage]
}

// MARK: - Firecrawl (search + extract, reference `plugins/web/firecrawl`)

public struct FirecrawlProvider: SearchProvider, ExtractProvider {
    public let name = "firecrawl"
    public let displayName = "Firecrawl"
    private let apiKey: String
    private let baseURL: String

    public init(apiKey: String, baseURL: String = "https://api.firecrawl.dev") {
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    public func isAvailable() -> Bool { !apiKey.isEmpty }
    public func isExtractAvailable() -> Bool { !apiKey.isEmpty }

    public func search(query: String, limit: Int) async throws -> [SearchResult] {
        var request = HTTPClientRequest(url: "\(baseURL)/v1/search")
        request.method = .POST
        request.headers.add(name: "Authorization", value: "Bearer \(apiKey)")
        request.headers.add(name: "Content-Type", value: "application/json")
        request.body = .bytes(try JSONSerialization.data(withJSONObject: [
            "query": query, "limit": min(limit, 10),
        ]))
        let data = try await HTTPTransport.execute(request)
        return try Self.parseSearchJSON(data)
    }

    internal static func parseSearchJSON(_ body: Data) throws -> [SearchResult] {
        let json = try JSONSerialization.jsonObject(with: body)
        guard let root = json as? [String: Any],
              let results = root["data"] as? [[String: Any]] else {
            throw SearchError.badResponse("missing 'data' array")
        }
        var out: [SearchResult] = []
        for item in results {
            let url = (item["url"] as? String) ?? ""
            guard !url.isEmpty else { continue }
            out.append(SearchResult(
                title: (item["title"] as? String) ?? "",
                url: url,
                description: (item["description"] as? String) ?? (item["markdown"] as? String) ?? "",
                position: out.count
            ))
        }
        return out
    }

    public func extract(urls: [String], format: String?) async throws -> [ExtractedPage] {
        var request = HTTPClientRequest(url: "\(baseURL)/v2/extract")
        request.method = .POST
        request.headers.add(name: "Authorization", value: "Bearer \(apiKey)")
        request.headers.add(name: "Content-Type", value: "application/json")
        let formats = format == "html" ? ["html"] : ["markdown", "html"]
        request.body = .bytes(try JSONSerialization.data(withJSONObject: [
            "urls": urls, "formats": formats,
        ]))
        let data = try await HTTPTransport.execute(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let perURL = (json["data"] as? [String: Any])?["extractedContent"] as? [String: Any] ?? [:]
        var pages: [ExtractedPage] = []
        for url in urls {
            let entry = perURL[url] as? [String: Any]
            let markdown = entry?["markdown"] as? String
            let html = entry?["html"] as? String
            let err = entry?["error"] as? String
            let content = markdown ?? html ?? (err ?? "")
            pages.append(ExtractedPage(
                url: url,
                content: content,
                format: markdown != nil ? "markdown" : (html != nil ? "html" : "text"),
                error: err
            ))
        }
        return pages
    }
}

// MARK: - Exa (search + extract, reference `plugins/web/exa`)

public struct ExaSearchProvider: SearchProvider, ExtractProvider {
    public let name = "exa"
    public let displayName = "Exa"
    private let apiKey: String

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    public func isAvailable() -> Bool { !apiKey.isEmpty }
    public func isExtractAvailable() -> Bool { !apiKey.isEmpty }

    public func search(query: String, limit: Int) async throws -> [SearchResult] {
        var request = HTTPClientRequest(url: "https://api.exa.ai/search")
        request.method = .POST
        request.headers.add(name: "x-api-key", value: apiKey)
        request.headers.add(name: "Content-Type", value: "application/json")
        request.body = .bytes(try JSONSerialization.data(withJSONObject: [
            "query": query, "numResults": limit,
        ]))
        let data = try await HTTPTransport.execute(request)
        return try Self.parseSearchJSON(data)
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
                description: (item["text"] as? String) ?? (item["highlights"] as? [String])?.joined(separator: " ") ?? "",
                position: out.count
            ))
        }
        return out
    }

    public func extract(urls: [String], format: String?) async throws -> [ExtractedPage] {
        // Exa: /extract (reference: contents deep-extraction).
        var request = HTTPClientRequest(url: "https://api.exa.ai/extract")
        request.method = .POST
        request.headers.add(name: "x-api-key", value: apiKey)
        request.headers.add(name: "Content-Type", value: "application/json")
        request.body = .bytes(try JSONSerialization.data(withJSONObject: [
            "urls": urls,
        ]))
        let data = try await HTTPTransport.execute(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let results = json["results"] as? [[String: Any]] ?? []
        var pages: [ExtractedPage] = []
        for item in results {
            let url = (item["url"] as? String) ?? ""
            let text = (item["text"] as? String) ?? ""
            let err = item["error"] as? String
            pages.append(ExtractedPage(
                url: url,
                content: text,
                format: "text",
                error: err
            ))
        }
        return pages
    }
}

// MARK: - Registry integration (reference legacy-preference walk)

public extension SearchRegistry {

    /// Reference legacy preference order (firecrawl → parallel → tavily →
    /// exa → searxng → brave → ddgs); parallel is not in-tree, so it is
    /// skipped at resolution time.
    static let legacyPreference: [String] = [
        "firecrawl", "parallel", "tavily", "exa", "searxng", "brave", "ddgs",
    ]

    /// Resolve the active extract backend: `web.extract_backend` /
    /// `web.backend` wins, then the first available extract-capable provider
    /// in legacy preference order (reference `_resolve_provider`).
    public func resolveExtractor(configured: String?) -> (ExtractProvider, String)? {
        let extractors = listProviders().compactMap { $0 as? ExtractProvider }
        if let backend = configured, !backend.isEmpty {
            if let exact = extractors.first(where: { $0.name == backend }) {
                return (exact, exact.name)
            }
        }
        for name in SearchRegistry.legacyPreference {
            if let p = extractors.first(where: { $0.name == name }), p.isExtractAvailable() {
                return (p, p.name)
            }
        }
        return extractors.first.map { ($0, $0.name) }
    }
}
