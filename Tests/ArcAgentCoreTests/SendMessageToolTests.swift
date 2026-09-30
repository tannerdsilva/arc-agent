import Testing
@testable import ArcAgentCore
import Foundation
import ServiceLifecycle

/// `send_message` tool tests (reference `tools/send_message_tool.py` parity)
/// against a mock platform adapter — no network, no bot token.
@Suite("Send message tool", .serialized)
struct SendMessageToolTests {

    final class MockAdapter: PlatformAdapter, @unchecked Sendable {
        let name: String
        var sent: [(message: OutgoingMessage, target: ChatTarget)] = []
        let incomingMessages: AsyncStream<IncomingMessage> = AsyncStream { _ in }

        init(name: String = "telegram") { self.name = name }

        func send(message: OutgoingMessage, to target: ChatTarget) async throws -> SendResult {
            sent.append((message, target))
            return SendResult(messageID: "m-\(sent.count)")
        }

        func run() async throws {
            try await Task.sleep(for: .seconds(3600))
        }
    }

    private func withDelivery(_ body: (DeliveryManager, MockAdapter) async throws -> Void) async throws {
        let dm = DeliveryManager()
        let adapter = MockAdapter()
        await dm.register(adapter: adapter)
        let oldDelivery = SendMessageTool.delivery
        let oldResolver = SendMessageTool.homeChatResolver
        SendMessageTool.delivery = dm
        SendMessageTool.homeChatResolver = nil
        defer {
            SendMessageTool.delivery = oldDelivery
            SendMessageTool.homeChatResolver = oldResolver
        }
        try await body(dm, adapter)
    }

    @Test("action='list' reports registered adapters")
    func listAction() async throws {
        try await withDelivery { _, _ in
            let out = try await SendMessageTool.entry.handler(["action": "list"])
            #expect(out.contains("telegram"))
            #expect(out.contains("platform:chat_id"))
        }
    }

    @Test("send delivers to platform:chat_id and returns a message id")
    func sendAction() async throws {
        try await withDelivery { _, adapter in
            let out = try await SendMessageTool.entry.handler(
                ["action": "send", "target": "telegram:1001", "message": "hello there"]
            )
            #expect(out.contains("Sent to telegram"))
            #expect(out.contains("m-1"))
            #expect(adapter.sent.count == 1)
            #expect(adapter.sent[0].target.platform == "telegram")
            #expect(adapter.sent[0].target.chatID == "1001")
            #expect(adapter.sent[0].message.text == "hello there")
        }
    }

    @Test("target with thread id parses into ChatTarget.threadID")
    func threadTarget() async throws {
        try await withDelivery { _, adapter in
            _ = try await SendMessageTool.entry.handler(
                ["action": "send", "target": "telegram:-1001:55", "message": "topic ping"]
            )
            #expect(adapter.sent[0].target.chatID == "-1001")
            #expect(adapter.sent[0].target.threadID == "55")
        }
    }

    @Test("bare platform uses the home-channel resolver when wired")
    func homeChannel() async throws {
        try await withDelivery { _, adapter in
            SendMessageTool.homeChatResolver = { platform in platform == "telegram" ? "home-42" : nil }
            let out = try await SendMessageTool.entry.handler(
                ["action": "send", "target": "telegram", "message": "hi"]
            )
            #expect(out.contains("Sent to telegram"))
            #expect(adapter.sent[0].target.chatID == "home-42")
        }
    }

    @Test("bare platform without a resolver errors with guidance")
    func noHome() async throws {
        try await withDelivery { _, _ in
            let out = try await SendMessageTool.entry.handler(
                ["action": "send", "target": "telegram", "message": "hi"]
            )
            #expect(out.contains("no home channel"))
        }
    }

    @Test("MEDIA: path becomes an attachment and is stripped from text")
    func mediaSplitting() {
        let (text, attachments) = SendMessageTool.collectMedia("Look at this\nMEDIA:/tmp/report.pdf\nthanks")
        #expect(text == "Look at this\nthanks")
        #expect(attachments.count == 1)
        #expect(attachments[0].filename == "report.pdf")
        #expect(attachments[0].url == "/tmp/report.pdf")
    }

    @Test("react/unreact report unsupported adapters")
    func reactUnsupported() async throws {
        try await withDelivery { _, _ in
            let out = try await SendMessageTool.entry.handler(
                ["action": "react", "target": "telegram:1", "message": "❤️"]
            )
            #expect(out.lowercased().contains("not supported"))
        }
    }

    @Test("unknown action errors")
    func unknownAction() async throws {
        try await withDelivery { _, _ in
            let out = try await SendMessageTool.entry.handler(["action": "yell", "message": "x"])
            #expect(out.contains("unknown action"))
        }
    }

    @Test("no delivery manager explains the gateway requirement")
    func noDelivery() async throws {
        let oldDelivery = SendMessageTool.delivery
        SendMessageTool.delivery = nil
        defer { SendMessageTool.delivery = oldDelivery }
        let out = try await SendMessageTool.entry.handler(
            ["action": "send", "target": "telegram:1", "message": "hi"]
        )
        #expect(out.contains("gateway"))
    }
}
