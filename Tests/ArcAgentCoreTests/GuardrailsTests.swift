import Testing
import Foundation
@testable import ArcAgentCore

/// Tests for the Hermes-parity guardrails: tool guardrails, redaction,
/// secret scope, file safety, message sanitization, think scrubber,
/// verification evidence, and background review.
@Suite("Guardrails")
struct GuardrailsTests {

    // MARK: - ToolGuardrails

    @Test("canonical args sort keys; signatures are deterministic")
    func canonical() {
        let a = ToolGuardrails.canonicalArgs(["b": 1, "a": 2])
        let b = ToolGuardrails.canonicalArgs(["a": 2, "b": 1])
        #expect(a == b)
        let s1 = ToolGuardrails.signature(tool: "terminal", args: ["command": "ls"])
        let s2 = ToolGuardrails.signature(tool: "terminal", args: ["command": "ls"])
        #expect(s1 == s2)
        #expect(s1 != ToolGuardrails.signature(tool: "terminal", args: ["command": "pwd"]))
        #expect(s1.count == 32) // 16-byte hex prefix
    }

    @Test("loop cap yields synthetic result after the cap (Hermes default 25)")
    func loopCap() async {
        let guardrails = ToolGuardrails()
        var sawSynthetic = false
        for i in 0..<27 {
            let decision = await guardrails.decide(toolName: "read_file", args: ["path": "/x-\(i)"])
            if case .synthetic(let msg) = decision {
                sawSynthetic = true
                #expect(msg.contains("Tool call limit reached for read_file"))
                #expect(i >= 25)
            }
        }
        #expect(sawSynthetic)
        // Any further call to the same tool is over the cap now.
        guard case .synthetic = await guardrails.decide(toolName: "read_file", args: ["path": "/y"]) else {
            Issue.record("post-cap calls must be synthetic")
            return
        }
    }

    @Test("repeated-identical-call detection (Hermes signature repeats)")
    func repeatDetection() async {
        let guardrails = ToolGuardrails()
        for _ in 0..<10 {
            let d = await guardrails.decide(toolName: "web_extract", args: ["url": "https://example.com"])
            if case .synthetic(let msg) = d {
                #expect(msg.contains("Repeated identical call"))
                return
            }
        }
        Issue.record("expected a synthetic repeat result")
    }

    @Test("web search budget capped at 50 per turn")
    func webBudget() async {
        // Raise the per-tool cap so the category budget is what fires.
        let guardrails = ToolGuardrails(limits: .init(perToolCaps: ["web_search": 200]))
        var synthetic = false
        for i in 0..<51 {
            let d = await guardrails.decide(toolName: "web_search", args: ["query": "x\(i)"])
            if case .synthetic(let msg) = d {
                synthetic = true
                #expect(msg.contains("Web search limit reached"))
            }
        }
        #expect(synthetic)
    }

    @Test("subagent budget capped at 50 per turn")
    func subagentBudget() async {
        let guardrails = ToolGuardrails(limits: .init(perToolCaps: ["delegate_task": 200]))
        var sawLimit = false
        for i in 0..<51 {
            let d = await guardrails.decide(toolName: "delegate_task", args: ["goal": "x\(i)"])
            if case .synthetic(let msg) = d {
                sawLimit = true
                #expect(msg.contains("Subagent spawn limit reached"))
            }
        }
        #expect(sawLimit)
    }

    @Test("resetTurn clears counters")
    func resetClears() async {
        let guardrails = ToolGuardrails()
        _ = await guardrails.decide(toolName: "web_search", args: ["query": "x"])
        await guardrails.resetTurn()
        for i in 0..<25 {
            guard case .allow = await guardrails.decide(toolName: "web_search", args: ["query": "x\(i)"]) else {
                Issue.record("counters did not reset")
                return
            }
        }
    }

    // MARK: - Redactor

    @Test("prefix patterns: sk-ant, ghp_, AIza (Hermes PREFIX_PATTERNS)")
    func prefixRedaction() {
        let out = Redactor.redact("key sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUV0123456789 and ghp_abcdefghijklmnopqrstuvwxyz0123456789 and AIzaSyABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        #expect(!out.contains("sk-ant-api03"))
        #expect(!out.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
        #expect(!out.contains("AIzaSyABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"))
        #expect(out.contains("[REDACTED]"))
    }

    @Test("JWT, PEM keys, and connection strings redact fully")
    func structuredRedaction() {
        let jwt = "header eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        #expect(!Redactor.redact(jwt).contains("eyJhbGciOiJ"))

        let pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA\n-----END RSA PRIVATE KEY-----"
        #expect(Redactor.redact(pem).contains("[REDACTED: private key]"))

        let conn = "postgres://user:secret@localhost:5432/db?sslmode=require"
        #expect(Redactor.redact(conn).contains("postgres://[REDACTED]"))
    }

    @Test("key/value lines and JSON api_key values redact (config/env shapes)")
    func keyValueRedaction() {
        let env = "export OPENAI_API_KEY=sk-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789\nprecious=notasecret"
        let out = Redactor.redactTerminalOutput(env)
        #expect(!out.contains("sk-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"))
        #expect(!out.contains("OPENAI_API_KEY=sk-"))

        let json = #"{"api_key": "sk-ant-0123456789abcdef0123456789abcdef", "model": "gpt-4o"}"#
        let red = Redactor.redact(json)
        #expect(!red.contains("sk-ant-0123456789abcdef0123456789abcdef"))
        #expect(red.contains(#""api_key": "[REDACTED]"#))
        #expect(red.contains("gpt-4o"))
    }

    @Test("URL query secrets and userinfo redact (Hermes URL rules)")
    func urlRedaction() {
        let q = "https://api.example.com/v1?api_key=supersecret1234567890&q=hello"
        let out = Redactor.redact(q)
        #expect(!out.contains("supersecret1234567890"))
        #expect(out.contains("q=hello"))

        let u = "https://user:passw0rd@example.com/path"
        #expect(Redactor.redact(u).contains("[REDACTED]@"))
    }

    // MARK: - SecretScope

    @Test("secret scope: global env names and prefix rules")
    func secretScope() {
        let scope = SecretScope(profile: "work", globalEnvPrefixes: ["MYAPP_"])
        #expect(scope.isSecretEnvVar("ARC_API_KEY"))
        #expect(scope.isSecretEnvVar("MYAPP_TOKEN"))
        #expect(scope.isSecretEnvVar("MYAPP_DEBUG")) // prefix rule matches
        #expect(!scope.isSecretEnvVar("OTHER_DEBUG"))
        #expect(scope.scopeLabel == "profile:work")
    }

    // MARK: - FileSafety

    @Test("file safety denies protected paths and warns on sandbox mirrors")
    func fileSafety() {
        #expect(FileSafety.isWriteDenied("~/.arc-agent/config.json"))
        #expect(FileSafety.isWriteDenied("~/.hermes/profiles/default/skills/x.md"))
        #expect(!FileSafety.isWriteDenied("/Users/brockwyma/Documents/x.txt"))
        #expect(FileSafety.sandboxMirrorWarning("/var/sandbox/one.txt") != nil)
        #expect(FileSafety.sandboxMirrorWarning("/Users/brockwyma/x.txt") == nil)
        #expect(FileSafety.expandHome("~") == FileManager.default.homeDirectoryForCurrentUser.path)
    }

    // MARK: - MessageSanitizer

    @Test("unicode sanitize replaces controls but keeps newlines")
    func unicodeSanitize() {
        let out = MessageSanitizer.sanitizeUnicode("a\u{0}b\nc\u{07}d")
        #expect(!out.contains("\u{0}"))
        #expect(!out.contains("\u{07}"))
        #expect(out.contains("\n"))
    }

    @Test("tool-call argument JSON repair (Hermes repair_tool_call_arguments)")
    func argRepair() {
        let broken = "{\"command\": \"echo a\nb\", \"path\": \"/tmp/x\"}"
        let repair = MessageSanitizer.repairToolCallArguments(broken)
        #expect(repair.repaired)
        let parsed = try? JSONSerialization.jsonObject(with: Data(repair.json.utf8)) as? [String: Any]
        #expect((parsed?["command"] as? String) == "echo a\nb")

        let bare = "{command: \"ls\"}"
        let repair2 = MessageSanitizer.repairToolCallArguments(bare)
        #expect(repair2.repaired)
        #expect((try? JSONSerialization.jsonObject(with: Data(repair2.json.utf8)) as? [String: Any])?["command"] as? String == "ls")
    }

    @Test("interrupted tool sequence closed with synthetic results, valid transcripts untouched")
    func interruptClose() {
        let calls = [ToolCall(id: "c1", function: ToolCallFunction(name: "terminal", arguments: "{}"))]
        let interruped = [
            Message(role: .user, content: "go"),
            Message(role: .assistant, content: nil, toolCalls: calls),
        ]
        let closed = MessageSanitizer.closeInterruptedToolSequence(interruped)
        #expect(closed.count == 3)
        #expect(closed.last?.role == .tool)
        #expect(closed.last?.toolCallID == "c1")

        let complete = interruped + [
            Message(role: .tool, content: "done", toolCallID: "c1"),
            Message(role: .user, content: "thanks"),
        ]
        let untouched = MessageSanitizer.closeInterruptedToolSequence(complete)
        #expect(untouched.count == complete.count)
    }

    @Test("deterministic tool call ids are stable")
    func deterministicIds() {
        #expect(MessageSanitizer.deterministicToolCallID(index: 2, name: "read_file")
            == MessageSanitizer.deterministicToolCallID(index: 2, name: "read_file"))
        #expect(MessageSanitizer.deterministicToolCallID(index: 2, name: "read_file")
            != MessageSanitizer.deterministicToolCallID(index: 3, name: "read_file"))
    }

    @Test("reasoning echo stripping and image stripping")
    func echoAndImages() {
        let prefix = "You are a helpful assistant with tool access."
        #expect(MessageSanitizer.stripReasoningEcho(prefix + " and more echo", systemPrefix: prefix) == "")
        let img = "text ![alt](https://x.com/i.png) and data:image/png;base64,AAAA\nmore"
        let out = MessageSanitizer.stripImages(img)
        #expect(!out.contains("data:image/png"))
        #expect(!out.contains("i.png"))
        #expect(out.contains("more"))
    }

    // MARK: - ThinkScrubber

    @Test("think scrubber strips fenced thinking and leading preambles")
    func thinkScrub() {
        let content = "thinking: let me consider\n```thinking\nhidden\n```\nFinal answer here."
        let out = ThinkScrubber.scrub(content)
        #expect(!out.contains("hidden"))
        #expect(out.contains("Final answer here."))
        #expect(!out.contains("thinking: let me consider"))
    }

    // MARK: - Verification evidence

    @Test("verify-worthy path filtering and nudge threshold (Hermes max 8)")
    func verification() {
        let paths = (0..<10).map { "Sources/x\($0).swift" } + ["/repo/.build/x.o", "/repo/Package.resolved"]
        let worthy = Verification.verifyWorthyPaths(paths)
        #expect(worthy.count == 10)
        #expect(!worthy.contains("/repo/.build/x.o"))

        let nudge = Verification.verifyNudge(changedPaths: (0..<9).map { "a\($0).swift" })
        #expect(nudge.contains("Verification"))

        let small = Verification.verifyNudge(changedPaths: ["a.swift"])
        #expect(small == "")
    }

    @Test("background review cadence and guidance injection")
    func backgroundReview() {
        let settings = BackgroundReview.Settings(afterToolCalls: 25, window: 8)
        #expect(BackgroundReview.isDue(settings: settings, totalToolCalls: 25))
        #expect(BackgroundReview.isDue(settings: settings, totalToolCalls: 50))
        #expect(!BackgroundReview.isDue(settings: settings, totalToolCalls: 24))
        #expect(!BackgroundReview.isDue(settings: BackgroundReview.Settings(), totalToolCalls: 25))

        #expect(BackgroundReview.guidanceBlock("OK") == nil)
        #expect(BackgroundReview.guidanceBlock("found a loop: stop repeating read_file") != nil)
    }
}
