import Foundation

/// Manages delivery of outgoing messages to platform adapters.
///
/// The delivery manager holds references to registered platform adapters
/// and routes outgoing messages to the correct adapter based on the
/// ``ChatTarget``'s platform field.
public actor DeliveryManager {
    private var adapters: [String: any PlatformAdapter] = [:]

    public init() {}

    /// Register a platform adapter for delivery.
    public func register(adapter: any PlatformAdapter) {
        adapters[adapter.name] = adapter
    }

    /// Platforms that are **local, request/response** — their answers travel
    /// over the caller's own response channel (HTTP body, WebSocket frame)
    /// rather than through a push adapter. These are never "unknown" and never
    /// need a registered adapter.
    ///
    /// - `api`   — HTTP `POST /v1/chat` (GatewayService.onChat)
    /// - `webui` — WebSocket chat (WebSocketHandler)
    ///
    /// Before this, a web/API turn reached `send(to:)` with platform "api" or
    /// "webui", no adapter was registered, `unknownPlatform` was thrown, and
    /// `SessionAgent`'s catch block removed the session and shut down its HTTP
    /// client — wiping conversation context on every turn.
    private let localPlatforms: Set<String> = ["api", "webui"]

    /// Send a message to the appropriate platform adapter.
    ///
    /// For local request/response platforms (`api`, `webui`) this is a no-op:
    /// the response has already been (or will be) delivered to the caller via
    /// its own channel (HTTP response / WS frame), so no push delivery is
    /// needed.
    public func send(message: OutgoingMessage, to target: ChatTarget) async throws {
        // Local request/response platforms need no push delivery.
        guard !localPlatforms.contains(target.platform) else { return }
        guard let adapter = adapters[target.platform] else {
            throw GatewayError.unknownPlatform(target.platform)
        }
        try await adapter.send(message: message, to: target)
    }

    /// Send a progress update (partial message) to a chat target.
    public func sendProgress(text: String, to target: ChatTarget) async throws {
        let message = OutgoingMessage(text: text, parseMode: "markdown", isPartial: true)
        try await send(message: message, to: target)
    }
}

/// Errors that can occur during gateway operation.
public enum GatewayError: Error, Sendable, CustomStringConvertible {
    case unknownPlatform(String)
    case adapterNotRunning(String)
    case agentCreationFailed(String)
    case sessionNotFound(String)

    public var description: String {
        switch self {
        case .unknownPlatform(let p): return "Unknown platform: \(p)"
        case .adapterNotRunning(let p): return "Adapter not running: \(p)"
        case .agentCreationFailed(let s): return "Agent creation failed: \(s)"
        case .sessionNotFound(let s): return "Session not found: \(s)"
        }
    }
}
