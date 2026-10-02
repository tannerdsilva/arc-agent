import Foundation
import Testing
@testable import ArcAgentCore

// MARK: - Session standards (reference `user-guide/sessions.md`)

@Suite("Session standards")
struct SessionStandardsTests {

    @Test("title sanitization: control, zero-width, RTL stripped")
    func sanitize() {
        #expect(SessionTitle.sanitized("Hello\tWorld\n") == "HelloWorld")  // controls stripped
        #expect(SessionTitle.sanitized("a\u{200B}b") == "ab")            // zero-width space
        #expect(SessionTitle.sanitized("a\u{200F}b") == "ab")            // RLM
        #expect(SessionTitle.sanitized("a\u{202E}b") == "ab")            // RLO
        #expect(SessionTitle.sanitized("  Title  ") == "Title")
        #expect(SessionTitle.sanitized("émoji 🎉 cjk 中文") == "émoji 🎉 cjk 中文")
        #expect(SessionTitle.sanitized(String(repeating: "x", count: 150)).count <= 100)
    }

    @Test("lineage numbering: my project → my project #2 → #3")
    func lineage() {
        #expect(SessionTitle.lineageNext("my project", existing: []) == "my project")
        #expect(SessionTitle.lineageNext("my project", existing: ["my project"]) == "my project #2")
        #expect(SessionTitle.lineageNext(
            "my project",
            existing: ["my project", "my project #2", "my project #3"]
        ) == "my project #4")
        #expect(SessionTitle.lineageNext("my project", existing: ["my project #2"]) == "my project")
    }

    @Test("session codec roundtrip preserves new fields")
    func codec() throws {
        let original = Session(
            id: "20261002_120000_ab12cd",
            model: "mock-1",
            provider: "mock",
            title: "My Session",
            messages: [Message(role: .user, content: "hi")],
            source: "telegram",
            userID: "user-7",
            parentSessionID: "parent-1",
            workspaceKey: "/Users/brockwyma/code/project",
            endedAt: Date(),
            inputTokens: 500,
            outputTokens: 250,
            systemPrompt: "sys"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        #expect(decoded.source == "telegram")
        #expect(decoded.userID == "user-7")
        #expect(decoded.parentSessionID == "parent-1")
        #expect(decoded.workspaceKey == "/Users/brockwyma/code/project")
        #expect(decoded.endedAt != nil)
        #expect(decoded.inputTokens == 500)
        #expect(decoded.outputTokens == 250)
        #expect(decoded.systemPrompt == "sys")
        #expect(decoded.messages.count == 1)  // count is re-derived by stores
    }

    @Test("legacy session JSON (without new fields) still decodes")
    func legacyDecode() throws {
        let legacy = #"{"id":"legacy-1","createdAt":1700000000,"updatedAt":1700000000,"model":"m","provider":"p","title":null,"messages":[]}"#
        let decoded = try JSONDecoder().decode(Session.self, from: Data(legacy.utf8))
        #expect(decoded.id == "legacy-1")
        #expect(decoded.source == nil)
        #expect(decoded.workspaceKey == nil)
    }

    @Test("export redaction scrubs secrets")
    func redact() {
        let out = SessionExporter.redact("key is sk-abcdefghijklmnopqrstuvwx, bearer eyJhbGciOiJIUzI1NiJ9.notreal, ghp_1234567890abcdefghijk")
        #expect(!out.contains("sk-abcdefghijklmnopqrstuvwx"))
        #expect(!out.contains("eyJhbGciOiJIUzI1NiJ9"))
        #expect(!out.contains("ghp_1234567890"))
        #expect(out.contains("[REDACTED]"))
    }

    @Test("jsonl export emits one record with valid JSON")
    func jsonlExport() throws {
        let session = Session(
            id: "s1", title: "test", messages: [Message(role: .user, content: "hello sk-abcdefghijklmnopqrst")],
            source: "cli"
        )
        let data = try SessionExporter.jsonlRecord(session: session, redacted: true)
        let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        let json = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        #expect(json?["id"] as? String == "s1")
        #expect(json?["source"] as? String == "cli")
        let messages = json?["messages"] as? [[String: Any]]
        #expect(messages?[0]["content"] as? String != "hello sk-abcdefghijklmnopqrst")
    }

    @Test("trace export shape (Claude Code JSONL)")
    func traceExport() throws {
        let session = Session(
            id: "s2",
            messages: [
                Message(role: .user, content: "hi"),
                Message(role: .assistant, content: "hello"),
                Message(role: .tool, content: "ok", name: "read_file", toolCallID: "call_1"),
            ]
        )
        let data = try SessionExporter.traceRecord(session: session)
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        let first = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        #expect(first?["type"] as? String == "message")
        #expect(first?["client"] as? String == "arc-agent")
    }

    @Test("prune filter: ended + inactive, source narrows, active never pruned")
    func prune() {
        let now = Date()
        let old = Session(id: "old", source: "telegram", endedAt: now.addingTimeInterval(-100 * 86_400))
        let fresh = Session(id: "fresh", source: "telegram", endedAt: now.addingTimeInterval(-5 * 86_400))
        let active = Session(id: "active", source: "telegram")

        #expect(SessionPruneFilter().matches(old, now: now))          // default 90 days
        #expect(!SessionPruneFilter().matches(fresh, now: now))
        #expect(!SessionPruneFilter().matches(active, now: now))
        #expect(SessionPruneFilter(olderThanDays: 3).matches(fresh, now: now))
        #expect(SessionPruneFilter(source: "cli").matches(old, now: now) == false)
        #expect(SessionPruneFilter(source: "telegram").matches(old, now: now))
    }
}
