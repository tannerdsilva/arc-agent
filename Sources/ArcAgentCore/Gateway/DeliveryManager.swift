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

    /// Send a message to the appropriate platform adapter.
    public func send(message: OutgoingMessage, to target: ChatTarget) async throws {
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
