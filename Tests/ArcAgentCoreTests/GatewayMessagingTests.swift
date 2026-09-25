import Testing
@testable import ArcAgentCore
import Foundation

// =========================================================================
// MARK: - Gateway Config Tests
// =========================================================================

@Suite("Gateway config")
struct GatewayConfigTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-gwcfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Defaults: everything disabled, no tokens")
    func defaults() {
        let config = GatewayConfig.load(home: URL(fileURLWithPath: "/nonexistent"), environment: [:])
        #expect(config.telegram.enabled == false)
        #expect(config.email.enabled == false)
        #expect(config.slack.enabled == false)
        #expect(config.telegram.botToken.isEmpty)
        #expect(config.slack.appToken.isEmpty)
    }

    @Test("JSON file: tokens + toggles land")
    func jsonFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = """
        { "telegram": {
            "enabled": true,
            "bot_token": "123:ABC",
            "allowed_users": "me,you",
            "allow_all_users": true,
            "home_channel": "-1001",
            "require_mention": true,
            "typing_indicator": false,
            "reply_to_mode": "all"
          },
          "email": {
            "enabled": true,
            "address": "bot@example.com",
            "password": "pw",
            "imap_host": "imap.example.com",
            "imap_port": 993,
            "imap_use_tls": true,
            "smtp_host": "smtp.example.com",
            "smtp_port": 465,
            "smtp_use_tls": true
          },
          "slack": {
            "enabled": true,
            "bot_token": "xoxb-1",
            "app_token": "xapp-1",
            "require_mention": true,
            "reply_to_mode": "all"
          }
        }
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("gateway.json"))
        let config = GatewayConfig.load(home: dir, environment: [:])
        #expect(config.telegram.enabled)
        #expect(config.telegram.botToken == "123:ABC")
        #expect(config.telegram.allowedUsers == ["me", "you"])
        #expect(config.telegram.allowAllUsers)
        #expect(config.telegram.homeChannel == "-1001")
        #expect(config.telegram.requireMention)
        #expect(config.telegram.typingIndicator == false)
        #expect(config.telegram.replyToMode == "all")
        #expect(config.email.address == "bot@example.com")
        #expect(config.email.imapPort == 993)
        #expect(config.slack.botToken == "xoxb-1")
        #expect(config.slack.requireMention)
    }

    @Test("Env overrides JSON (Hermes parity)")
    func envOverrides() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = """
        { "telegram": { "enabled": true, "bot_token": "file-token" } }
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("gateway.json"))
        let config = GatewayConfig.load(home: dir, environment: [
            "TELEGRAM_BOT_TOKEN": "env-token",
            "TELEGRAM_ALLOW_ALL_USERS": "1",
            "TELEGRAM_HOME_CHANNEL": "-42",
        ])
        #expect(config.telegram.botToken == "env-token")
        #expect(config.telegram.enabled)
        #expect(config.telegram.allowAllUsers)
        #expect(config.telegram.homeChannel == "-42")
    }

    @Test("Env-only config enables platforms without a file")
    func envOnly() {
        let config = GatewayConfig.load(home: URL(fileURLWithPath: "/nonexistent"), environment: [
            "TELEGRAM_BOT_TOKEN": "abc",
            "EMAIL_ADDRESS": "a@b.com",
            "EMAIL_PASSWORD": "x",
            "SLACK_BOT_TOKEN": "xoxb-2",
            "SLACK_APP_TOKEN": "xapp-2",
        ])
        #expect(config.telegram.enabled)
        #expect(config.email.enabled)
        #expect(config.email.address == "a@b.com")
        #expect(config.slack.enabled)
    }
}

// =========================================================================
// MARK: - Authz Tests
// =========================================================================

@Suite("Authz policy")
struct AuthzTests {

    private let chat = ChatTarget(platform: "telegram", chatID: "-1001")
    private let dm = ChatTarget(platform: "telegram", chatID: "123")

    @Test("Allow-all users permits any sender")
    func allowAll() {
        let policy = AuthzPolicy(allowAllUsers: true)
        #expect(policy.allows(senderID: "anyone", chat: chat, isMention: false))
    }

    @Test("Allowlist rejects unknown senders")
    func allowlist() {
        let policy = AuthzPolicy(allowedUsers: ["user1"])
        #expect(policy.allows(senderID: "user1", chat: chat, isMention: true))
        #expect(!policy.allows(senderID: "intruder", chat: chat, isMention: true))
        #expect(!policy.allows(senderID: nil, chat: chat, isMention: true))
    }

    @Test("Require-mention gates channels, not DMs")
    func mentionGating() {
        let policy = AuthzPolicy(allowedUsers: ["u"], requireMention: true)
        #expect(!policy.allows(senderID: "u", chat: chat, isMention: false, chatType: "channel"))
        #expect(policy.allows(senderID: "u", chat: chat, isMention: true, chatType: "channel"))
        #expect(policy.allows(senderID: "u", chat: dm, isMention: false, chatType: "dm"))
    }

    @Test("Chat allowlist matches threads by parent")
    func chatGate() {
        let policy = AuthzPolicy(allowAllUsers: true, allowedChats: ["-1001"])
        #expect(policy.allows(senderID: "u", chat: chat, isMention: true))
        let threadChat = ChatTarget(platform: "slack", chatID: "C1", parentChatID: "-1001")
        #expect(policy.allows(senderID: "u", chat: threadChat, isMention: true))
        let other = ChatTarget(platform: "slack", chatID: "C2")
        #expect(!policy.allows(senderID: "u", chat: other, isMention: true))
    }

    @Test("Comma-separated id parsing")
    func parseIds() {
        #expect(AuthzPolicy.parseIds(" a, b ,c ") == ["a", "b", "c"])
        #expect(AuthzPolicy.parseIds("") == [])
    }
}

// =========================================================================
// MARK: - Platform Format Tests
// =========================================================================

@Suite("Platform formats & chunking")
struct PlatformFormatTests {

    @Test("Telegram escapes all MarkdownV2 specials")
    func telegramEscapes() {
        let out = TelegramFormat.format("a_b *c* [d](e) `f` ~g> h#i+j-k=l|m{n}o.p!q")
        #expect(out == "a\\_b \\*c\\* \\[d\\]\\(e\\) `f` \\~g\\> h\\#i\\+j\\-k\\=l\\|m\\{n\\}o\\.p\\!q")
    }

    @Test("Telegram leaves code fence contents alone")
    func telegramFence() {
        let text = "before [x](y)\n```\n*not italic* _not_\n```\nafter"
        let out = TelegramFormat.format(text)
        #expect(out.contains("\\[x\\]\\(y\\)"))     // [x](y) escaped OUTSIDE fence
        #expect(out.contains("*not italic*"))       // fence content untouched
        #expect(out.contains("_not_"))
        #expect(!out.contains("\\*not italic\\*"))  // no escaping inside fence
        #expect(out.contains("before"))
        #expect(out.contains("after"))
    }

    @Test("Slack mrkdwn conversions")
    func slackConversions() {
        let out = SlackFormat.format("## Title\n- item\n[link](https://a.b)\n`code`")
        let lines = out.split(separator: "\n").map(String.init)
        #expect(lines[0] == "*Title*")
        #expect(lines[1] == "• item")
        #expect(lines[2] == "<https://a.b|link>")
        #expect(lines[3] == "`code`")
    }

    @Test("Slack code fences are untouched")
    func slackFences() {
        let out = SlackFormat.format("```\n- not a bullet\n## not a heading\n```")
        #expect(out.contains("- not a bullet"))
        #expect(out.contains("## not a heading"))
    }

    @Test("Chunker splits at boundaries with suffix")
    func chunkBasics() {
        let text = String(repeating: "word ", count: 100)
        let pieces = PlatformChunker.chunk(String(text), maxLength: 34)
        #expect(pieces.count > 1)
        #expect(pieces.allSatisfy { $0.count <= 34 })
        #expect(pieces.dropLast().allSatisfy { $0.hasSuffix(" …") })
    }

    @Test("Chunker never splits a code fence")
    func chunkFence() {
        let fence = String(repeating: "x", count: 100)
        let text = "start\n```\n\(fence)\n```\nend"
        let pieces = PlatformChunker.chunk(text, maxLength: 40)
        // The fence travels whole (chunk 1 is over-limit by design — never
        // split); the trailing line becomes its own chunk.
        #expect(pieces.count == 2)
        #expect(String(pieces.joined()) == text)
        // Fence lives intact inside one chunk.
        let fenceChunk = pieces.first!
        #expect(fenceChunk.contains("```"))
        #expect(fenceChunk.filter { $0 == "`" }.count == 6)
    }

    @Test("HTML strip removes tags and entities")
    func htmlStrip() {
        let out = EmailFormat.stripHTML("<p>Hello&nbsp;<b>World</b></p><br>Foo &amp; Bar")
        #expect(out == "Hello World\nFoo & Bar")
    }
}

// =========================================================================
// MARK: - Email Parser Tests
// =========================================================================

@Suite("Email message parser")
struct EmailParserTests {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    @Test("Parses headers and plain body")
    func plain() {
        let raw = """
        From: Alice <alice@example.com>
        To: bot@example.com
        Subject: =?utf-8?B?SGVsbG8gV29ybGQ=?=
        Message-ID: <abc@example.com>

        Hello there
        """
        let parsed = EmailMessageParser.parse(data(raw))
        #expect(parsed != nil)
        #expect(parsed?.from == "alice@example.com")
        #expect(parsed?.subject == "Hello World")
        #expect(parsed?.messageID == "abc@example.com")
        #expect(parsed?.body.contains("Hello there") == true)
    }

    @Test("Multipart prefers text/plain over HTML")
    func multipart() {
        let raw = """
        From: bob@example.com
        Subject: Multi
        Content-Type: multipart/mixed; boundary="BOUND"

        --BOUND
        Content-Type: text/plain; charset=utf-8

        plain body
        --BOUND
        Content-Type: text/html; charset=utf-8

        <b>html body</b>
        --BOUND--
        """
        let parsed = EmailMessageParser.parse(data(raw))
        #expect(parsed?.body.contains("plain body") == true)
        #expect(parsed?.body.contains("html body") == false)
    }

    @Test("Quoted-printable body decodes")
    func quotedPrintable() {
        let raw = """
        From: c@example.com
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        caf=C3=A9=
         line
        """
        let parsed = EmailMessageParser.parse(data(raw))
        #expect(parsed?.body.contains("café line") == true)
    }

    @Test("Base64 body decodes")
    func base64Body() {
        let encoded = Data("encoded body".utf8).base64EncodedString()
        let raw = """
        From: d@example.com
        Content-Type: text/plain
        Content-Transfer-Encoding: base64

        \(encoded)
        """
        let parsed = EmailMessageParser.parse(data(raw))
        #expect(parsed?.body.contains("encoded body") == true)
    }

    @Test("Threading headers extracted")
    func threading() {
        let raw = """
        From: e@example.com
        In-Reply-To: <prev@example.com>
        References: <root@example.com> <prev@example.com>

        body
        """
        let parsed = EmailMessageParser.parse(data(raw))
        #expect(parsed?.inReplyTo == "prev@example.com")
        #expect(parsed?.references == "root@example.com> <prev@example.com")
    }

    @Test("Name <addr> extraction")
    func addressExtraction() {
        #expect(EmailMessageParser.extractAddress("Jane Doe <jane@x.io>") == "jane@x.io")
        #expect(EmailMessageParser.extractAddress("jane@x.io") == "jane@x.io")
    }
}
