import Foundation
import AsyncHTTPClient
import NIO

/// Web search/extract backend registry (Hermes `agent/web_search_provider.py`
/// + `agent/web_search_registry.py` port).
///
/// Contract mirrored from Hermes:
/// - A provider advertises a stable lowercase `name`, a cheap `isAvailable()`
///   check (no network), and either/both of `search` / `extract` capabilities.
/// - The active provider is chosen by config (`web.search_backend`,
///   `web.extract_backend`, legacy `web.backend`) against the registered
///   providers, falling back to the first available one.
/// - `search` returns `SearchResult`s; the tool wrapper renders them.
public protocol SearchProvider: Sendable {
    /// Stable short identifier used in `web.search_backend` config values.
    var name: String { get }
    /// Human-readable label.
    var displayName: String { get }
    /// Cheap availability check (env var present, endpoint set). No network.
    func isAvailable() -> Bool
    /// Perform a web search.
    func search(query: String, limit: Int) async throws -> [SearchResult]
}

public extension SearchProvider {
    /// Default label (matches the stable identifier).
    var displayName: String { name }
}

/// A single normalized search result (Hermes response-shape contract).
public struct SearchResult: Sendable, Equatable {
    public let title: String
    public let url: String
    public let description: String
    public let position: Int

    public init(title: String, url: String, description: String, position: Int) {
        self.title = title
        self.url = url
        self.description = description
        self.position = position
    }
}

public enum SearchError: Error, CustomStringConvertible {
    case noProviderConfigured
    case providerUnavailable(String)
    case http(Int, String)
    case badResponse(String)

    public var description: String {
        switch self {
        case .noProviderConfigured:
            return "No web search provider available. Set SEARCH_API_KEY / BRAVE_API_KEY / TAVILY_API_KEY or configure web.search_backend."
        case .providerUnavailable(let name):
            return "Web search provider '\(name)' is not available (missing credentials or endpoint)."
        case .http(let code, let body):
            return "Search request failed (\(code)): \(body.prefix(200))"
        case .badResponse(let detail):
            return "Search response could not be parsed: \(detail.prefix(200))"
        }
    }
}

/// Registry of search providers (Hermes `web_search_registry.py`).
public actor SearchRegistry {
    public static let shared = SearchRegistry()

    private var providers: [SearchProvider] = []
    private var configuredBackend: String?

    /// Register a provider instance (built-ins register at first use).
    public func register(_ provider: SearchProvider) {
        if let idx = providers.firstIndex(where: { $0.name == provider.name }) {
            providers[idx] = provider
        } else {
            providers.append(provider)
        }
    }

    /// Set the configured backend name (from `web.search_backend` / `web.backend`).
    public func configure(backend: String?) {
        configuredBackend = backend?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func listProviders() -> [SearchProvider] {
        providers
    }

    /// Reset registry state (tests, Hermes `_reset_for_tests`).
    public func reset() {
        providers = []
        configuredBackend = nil
    }

    /// Resolve the active search provider: explicit config match first, then
    /// first available provider (Hermes `_resolve` semantics).
    public func resolve() -> SearchProvider? {
        let candidates = providers.filter { $0.isAvailable() }
        if let backend = configuredBackend, !backend.isEmpty {
            if let exact = candidates.first(where: { $0.name == backend }) {
                return exact
            }
            if let fallback = providers.first(where: { $0.name == backend }) {
                // configured but unavailable — let the caller report it
                return fallback
            }
        }
        return candidates.first
    }

    /// Resolve and run a search; throws `noProviderConfigured`/`providerUnavailable`
    /// with Hermes-style messages when no provider can service the call.
    public func perform(query: String, limit: Int) async throws -> [SearchResult] {
        guard let provider = resolve() else {
            throw SearchError.noProviderConfigured
        }
        guard provider.isAvailable() else {
            throw SearchError.providerUnavailable(provider.name)
        }
        return try await provider.search(query: query, limit: limit)
    }
}

// MARK: - Environment helper (Hermes `get_provider_env`)

public enum SearchEnv {
    /// Config-aware env lookup: `os.environ` first, then `~/.arc/.env`
    /// (parsed KEY=VALUE lines), then empty. Mirrors Hermes.
    public static func get(_ name: String) -> String {
        if let v = ProcessInfo.processInfo.environment[name], !v.isEmpty {
            return v.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let envPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arc/.env")
        guard let content = try? String(contentsOf: envPath, encoding: .utf8) else {
            return ""
        }
        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            if key == name {
                return String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }
}
