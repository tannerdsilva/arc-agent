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
    @discardableResult
    public func send(message: OutgoingMessage, to target: ChatTarget) async throws -> SendResult {
        // Local request/response platforms need no push delivery.
        guard !localPlatforms.contains(target.platform) else {
            return SendResult(messageID: nil)
        }
        guard let adapter = adapters[target.platform] else {
            throw GatewayError.unknownPlatform(target.platform)
        }
        return try await adapter.send(message: message, to: target)
    }

    /// Whether the adapter for `target.platform` supports in-place edits
    /// (the live-streaming path).
    public func canEdit(to target: ChatTarget) -> Bool {
        guard !localPlatforms.contains(target.platform),
              let adapter = adapters[target.platform] else { return false }
        return adapter.canEditMessages
    }

    /// Replace a previously streamed message in place.
    public func update(
        messageID: String,
        text: String,
        parseMode: String?,
        to target: ChatTarget
    ) async throws {
        guard let adapter = adapters[target.platform] else {
            throw GatewayError.unknownPlatform(target.platform)
        }
        try await adapter.sendUpdate(messageID: messageID, text: text, parseMode: parseMode, to: target)
    }

    /// Show the platform's typing indicator in `target`. No-op for local
    /// platforms and adapters without a typing API.
    public func sendTyping(to target: ChatTarget) async throws {
        guard !localPlatforms.contains(target.platform),
              let adapter = adapters[target.platform] else { return }
        try await adapter.sendTyping(to: target)
    }

    /// Delete a previously sent message through the adapter.
    public func delete(messageID: String, to target: ChatTarget) async throws {
        guard let adapter = adapters[target.platform] else {
            throw GatewayError.unknownPlatform(target.platform)
        }
        try await adapter.deleteMessage(messageID: messageID, to: target)
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
    case unsupportedOperation(String)

    public var description: String {
        switch self {
        case .unknownPlatform(let p): return "Unknown platform: \(p)"
        case .adapterNotRunning(let p): return "Adapter not running: \(p)"
        case .agentCreationFailed(let s): return "Agent creation failed: \(s)"
        case .sessionNotFound(let s): return "Session not found: \(s)"
        case .unsupportedOperation(let s): return "Unsupported operation: \(s)"
        }
    }
}
