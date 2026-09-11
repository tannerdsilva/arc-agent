import Foundation

// MARK: - Provider registries (Hermes web_search/image_gen registries)

/// A pluggable web-search backend (Hermes WebSearchProvider protocol).
public protocol WebSearchProvider: Sendable {
    var name: String { get }
    func search(query: String, maxResults: Int) async throws -> [String]
}

/// Name → provider registry with an active provider (Hermes
/// `web_search_registry.get_active_provider`; selection via
/// `WEB_SEARCH_PROVIDER`, default "default").
public actor WebSearchRegistry {
    public static let shared = WebSearchRegistry()
    private var providers: [String: any WebSearchProvider] = [:]

    public func register(_ provider: any WebSearchProvider) {
        providers[provider.name] = provider
    }

    public func active() async -> (any WebSearchProvider)? {
        if let name = ProcessInfo.processInfo.environment["WEB_SEARCH_PROVIDER"],
           let provider = providers[name] { return provider }
        return providers["default"] ?? providers.values.first
    }
}

/// A pluggable image-generation backend (Hermes image_gen_registry).
public protocol ImageGenProvider: Sendable {
    var name: String { get }
    func generate(prompt: String) async throws -> Data
}

public actor ImageGenRegistry {
    public static let shared = ImageGenRegistry()
    private var providers: [String: any ImageGenProvider] = [:]

    public func register(_ provider: any ImageGenProvider) {
        providers[provider.name] = provider
    }

    public func active() -> (any ImageGenProvider)? {
        if let name = ProcessInfo.processInfo.environment["IMAGE_GEN_PROVIDER"],
           let provider = providers[name] { return provider }
        return providers["default"] ?? providers.values.first
    }
}

// MARK: - Context engines (Hermes `context_engine.py`)

/// Pluggable context selection/compression engines (Hermes ContextEngine
/// ABC: `should_compress`, `select_context`, `prune_tool_results_only`).
public protocol ContextEngine: Sendable {
    var name: String { get }
    /// Whether compression should run for this context size.
    func shouldCompress(currentTokens: Int, threshold: Int) -> Bool
    /// Pick the messages that survive a compression pass (prefix window);
    /// `protectFirstN` messages are never dropped.
    func selectContext(messages: [Message], threshold: Int, protectFirstN: Int) -> [Message]
    /// Tool-result-only pruning: drop the largest tool results first.
    func pruneToolResultsOnly(messages: [Message], maxBytes: Int) -> [Message]
}

/// Hermes defaults: compress at threshold (typically context/2), protect the
/// first N messages (identity), keep tool results bounded.
public struct DefaultContextEngine: ContextEngine {
    public let name = "default"
    public let toolResultBudget: Int

    public init(toolResultBudget: Int = 32_000) {
        self.toolResultBudget = toolResultBudget
    }

    public func shouldCompress(currentTokens: Int, threshold: Int) -> Bool {
        currentTokens >= threshold
    }

    public func selectContext(messages: [Message], threshold: Int, protectFirstN: Int) -> [Message] {
        guard messages.count > protectFirstN else { return messages }
        // Protect the head (identity) and keep the most recent half; drop the
        // middle. The protected head never loses its first message.
        let keepHead = protectFirstN
        let keepTail = max(protectFirstN, messages.count / 2)
        let tailStart = max(keepHead, messages.count - keepTail)
        return Array(messages[..<keepHead]) + Array(messages[tailStart...])
    }

    public func pruneToolResultsOnly(messages: [Message], maxBytes: Int) -> [Message] {
        var budget = maxBytes
        var result: [Message] = []
        for message in messages {
            if message.role == .tool, let content = message.content, content.utf8.count > budget {
                // Trim the oldest tool results to the remaining budget.
                continue
            }
            if message.role == .tool, let content = message.content {
                budget -= content.utf8.count
                if budget < 0 { continue }
            }
            result.append(message)
        }
        return result
    }
}

/// Engine router: resolves the configured engine name to an implementation
/// (Hermes `agent_init` context engine selection; `ARC_CONTEXT_ENGINE` env).
public enum ContextEngineRouter {
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> any ContextEngine {
        switch environment["ARC_CONTEXT_ENGINE"] {
        case "prune_tool_results":
            return PruneToolResultsEngine()
        default:
            return DefaultContextEngine()
        }
    }
}

/// Alternative engine: keep the conversation, only prune tool results.
public struct PruneToolResultsEngine: ContextEngine {
    public let name = "prune_tool_results"
    public func shouldCompress(currentTokens: Int, threshold: Int) -> Bool { currentTokens >= threshold }
    public func selectContext(messages: [Message], threshold: Int, protectFirstN: Int) -> [Message] { messages }
    public func pruneToolResultsOnly(messages: [Message], maxBytes: Int) -> [Message] {
        DefaultContextEngine().pruneToolResultsOnly(messages: messages, maxBytes: maxBytes)
    }
}
