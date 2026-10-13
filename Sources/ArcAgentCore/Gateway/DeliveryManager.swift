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

    /// Names of the platforms with a registered adapter (for `send_message`
    /// action='list').
    public func adapterNames() -> [String] {
        Array(adapters.keys)
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

    /// Response-silence convention (reference stream-consumer silence): a
    /// final assistant response that is exactly `NO_REPLY` or `[SILENT]`
    /// (after trimming whitespace) means "intentional silence" — the turn
    /// happened, but nothing is delivered to the platform. This mirrors the
    /// Hermes gateway's whole-response filter for messaging platforms.
    /// Local request/response platforms (`api`, `webui`) are not filtered
    /// here: their caller sees the raw response text on its own channel.
    public static func isSilentResponse(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "NO_REPLY" || trimmed == "[SILENT]"
    }

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
        // Response-silence convention: NO_REPLY / [SILENT] → no delivery.
        if Self.isSilentResponse(message.text) {
            return SendResult(messageID: nil)
        }
        guard let adapter = adapters[target.platform] else {
            throw GatewayError.unknownPlatform(target.platform)
        }
        // Deliverable mode (reference `features/deliverable-mode.md`):
        // final messages carrying absolute file paths ship the files as
        // native attachments; failures keep the path + a note (never silent).
        var message = message
        if !message.isPartial {
            let extracted = DeliverableExtractor.extract(message.text)
            if !extracted.paths.isEmpty {
                let plan = Self.makeDeliverablePlan(paths: extracted.paths, platform: target.platform)
                var text = extracted.clean.trimmingCharacters(in: .whitespacesAndNewlines)
                if !plan.notes.isEmpty {
                    text += "\n\n" + plan.notes.joined(separator: "\n")
                }
                var attachments = message.attachments ?? []
                attachments.append(contentsOf: plan.files)
                message = OutgoingMessage(
                    text: text,
                    parseMode: message.parseMode,
                    isPartial: false,
                    attachments: attachments,
                    metadata: message.metadata
                )
            }
        }
        return try await adapter.send(message: message, to: target)
    }

    /// Platform file-size caps (reference: Telegram 50 MB, Slack 16 MB …).
    static func deliverableLimits(platform: String) -> Int {
        switch platform {
        case "telegram": return 50 * 1024 * 1024
        case "slack": return 16 * 1024 * 1024
        default: return 25 * 1024 * 1024
        }
    }

    /// Resolve deliverable paths to attachment files; missing/oversized
    /// entries become visible notes (reference failure handling).
    static func makeDeliverablePlan(paths: [String], platform: String) -> (files: [OutgoingMessage.Attachment], notes: [String]) {
        let limit = deliverableLimits(platform: platform)
        var files: [OutgoingMessage.Attachment] = []
        var notes: [String] = []
        for path in paths {
            guard FileManager.default.fileExists(atPath: path) else {
                notes.append("⚠️ Could not attach \(path): file not found.")
                continue
            }
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            if size > Int64(limit) {
                notes.append("⚠️ Could not attach \(path): file is \(size / 1_048_576) MB (limit \(limit / 1_048_576) MB).")
                continue
            }
            files.append(.local(path: path))
        }
        return (files, notes)
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
