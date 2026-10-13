import Foundation

// MARK: - send_message (reference `tools/send_message_tool.py`)

/// Tool: `send_message` — send a message to a connected messaging platform,
/// or list available targets.
///
/// Arc's gateway delivers through registered ``PlatformAdapter``s via
/// ``DeliveryManager``. This tool is wired by the gateway at startup
/// (``SendMessageTool.delivery``); outside a running gateway it explains
/// itself. Arc's bot-mode tools (`send_bot_message`/`send_group_chat`) remain
/// for agent-to-agent roster messaging; this is the human-facing platform
/// delivery surface.
public enum SendMessageTool {

    /// The delivery manager. Wired by ``GatewayService`` (and by tests).
    public nonisolated(unsafe) static var delivery: DeliveryManager?

    /// Resolves a bare platform name to its home chat id (wired by the
    /// gateway from its platform config; nil when unknown).
    public nonisolated(unsafe) static var homeChatResolver: (@Sendable (String) async -> String?)?

    public static let entry = ToolEntry(
        name: "send_message",
        toolset: "messaging",
        description: "Send a message to a connected messaging platform, or list available targets.\n\n"
            + "IMPORTANT: When the user asks to send to a specific channel or person "
            + "(not just a bare platform name), call send_message(action='list') FIRST to see "
            + "available targets, then send to the correct one.\n"
            + "If the user just says a platform name like 'send to telegram', send directly "
            + "to the home channel without listing first.\n\n"
            + "Target format: 'platform' (uses home channel), 'platform:chat_id', or "
            + "'platform:chat_id:thread_id' for Telegram topics. Examples: 'telegram', "
            + "'telegram:-1001234567890:17585'.",
        schema: .object(
            description: "Send message parameters",
            properties: [
                "action": .string(description: "'send' (default) sends a message. 'list' returns all available targets across connected platforms. 'react'/'unreact' attach/retract a reaction (not supported by connected platforms yet)."),
                "target": .string(description: "Delivery target: 'platform', 'platform:chat_id', or 'platform:chat_id:thread_id'."),
                "message": .string(description: "The message text to send. To send an image or file, include MEDIA:<local_path> in the message — the platform delivers it as an attachment."),
                "emoji": .string(description: "For action='react'"),
                "message_id": .string(description: "For action='react'/'unreact'"),
            ],
            required: []
        ),
        handler: { args in
            let action = (args["action"] as? String) ?? "send"
            switch action {
            case "list":
                return await handleList()
            case "send":
                return try await handleSend(args)
            case "react", "unreact":
                return "Not supported: none of the connected platform adapters implement reactions. "
                    + "(the reference implementation supports this on iMessage/Photon only; Arc has no such adapter yet.)"
            default:
                return "Error: unknown action '\(action)'. Valid actions: send, list, react, unreact"
            }
        },
        emoji: "✉️"
    )

    // MARK: - Actions

    static func handleList() async -> String {
        guard let delivery = delivery else {
            return "Error: no delivery manager is wired in this context (is the gateway running?). "
                + "send_message is available when arc serves the gateway."
        }
        let adapters = await delivery.adapterNames().sorted()
        var lines: [String] = ["Connected messaging platforms (targets use 'platform:chat_id'):"]
        if adapters.isEmpty {
            lines.append("  (none registered)")
        } else {
            lines.append(contentsOf: adapters.map { "  \($0)" })
        }
        lines.append("")
        lines.append("Examples: telegram, telegram:-1001234567890, telegram:-1001234567890:17585")
        return lines.joined(separator: "\n")
    }

    static func handleSend(_ args: [String: Any]) async throws -> String {
        guard let delivery = delivery else {
            return "Error: no delivery manager is wired in this context (is the gateway running?)."
        }
        let targetRaw = (args["target"] as? String) ?? ""
        let rawMessage = (args["message"] as? String) ?? ""
        guard !rawMessage.isEmpty else {
            return "Error: 'message' is required for action='send'."
        }
        // Parse target: platform[:chat_id[:thread_id]]
        let parts = targetRaw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let platform = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !platform.isEmpty else {
            return "Error: 'target' must name a platform (e.g. 'telegram', 'telegram:-1001234567890')."
        }
        var chatID = parts.count > 1 ? parts[1] : ""
        let threadID = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
        if chatID.isEmpty {
            if let resolver = homeChatResolver, let home = await resolver(platform) {
                chatID = home
            } else {
                return "Error: target '\(targetRaw)' has no chat id and no home channel is known for '\(platform)'. Use '\(platform):chat_id'."
            }
        }
        // MEDIA:<path> tokens become attachments; the rest stays as text.
        let (text, attachments) = collectMedia(rawMessage)
        let target = ChatTarget(platform: platform, chatID: chatID, threadID: threadID)
        do {
            let result = try await delivery.send(
                message: OutgoingMessage(text: text, attachments: attachments.isEmpty ? nil : attachments),
                to: target
            )
            if let id = result.messageID {
                return "Sent to \(platform) (message \(id))."
            }
            return "Sent to \(platform)."
        } catch {
            return "Error: could not deliver to '\(targetRaw)': \(String(describing: error))"
        }
    }

    /// Split `MEDIA:<path>` tokens out of the message into attachments.
    static func collectMedia(_ message: String) -> (String, [OutgoingMessage.Attachment]) {
        var attachments: [OutgoingMessage.Attachment] = []
        var rest: [String] = []
        for line in message.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("MEDIA:") {
                let path = String(trimmed.dropFirst("MEDIA:".count))
                let expanded = URL(fileURLWithPath: path).standardizedFileURL.path
                let filename = (expanded as NSString).lastPathComponent
                attachments.append(OutgoingMessage.Attachment(filename: filename, url: expanded))
            } else {
                rest.append(String(line))
            }
        }
        return (rest.joined(separator: "\n"), attachments)
    }
}
