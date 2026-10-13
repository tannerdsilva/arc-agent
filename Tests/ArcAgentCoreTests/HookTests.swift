import Foundation
import Testing
@testable import ArcAgentCore

// MARK: - Event Hooks (reference `user-guide/features/hooks.md`)

@Suite("Event hooks")
struct HookTests {

    @Test("wildcard matching")
    func wildcardMatching() {
        let hook = FileHook(
            name: "cmd-logger", description: "",
            events: ["command:*"], handlerURL: URL(fileURLWithPath: "/tmp/x"),
            interpreter: nil
        )
        #expect(hook.matches("command:model"))
        #expect(hook.matches("command:reset"))
        #expect(!hook.matches("agent:start"))

        let exact = FileHook(name: "e", description: "", events: ["agent:end"],
                             handlerURL: URL(fileURLWithPath: "/tmp/x"), interpreter: nil)
        #expect(exact.matches("agent:end"))
        #expect(!exact.matches("agent:start"))
    }

    @Test("HOOK.yaml parser")
    func yamlParser() {
        let yaml = """
        name: long-task-alert
        description: Alert when agent takes many steps
        events:
          - agent:step
          - command:*
        """
        let manifest = HookYAMLParser.parse(yaml)
        #expect(manifest?.name == "long-task-alert")
        #expect(manifest?.events == ["agent:step", "command:*"])
    }

    @Test("hook value round trip")
    func hookContextValues() {
        let ctx = HookContext([
            "iteration": .int(11),
            "in_place": .bool(true),
            "tools": .array(["terminal", "patch"]),
            "name": .string("x"),
        ])
        #expect(ctx.int("iteration") == 11)
        #expect(ctx.bool("in_place") == true)
        #expect(ctx.array("tools") == ["terminal", "patch"])
        #expect(ctx.string("name") == "x")
        #expect(ctx.string("missing") == nil)
    }

    @Test("programmatic observer fires on emit")
    func observerFires() async {
        let bus = HookBus()
        let fired = ValueBox<String?>(nil)
        await bus.register(events: ["agent:step"]) { event, ctx in
            await fired.setValue(event + ":" + (ctx.int("iteration").map(String.init) ?? "?"))
        }
        await bus.emit("agent:step", ["iteration": .int(3)])
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(await fired.getValue() == "agent:step:3")
    }

    @Test("outbound target config decode + secret resolution")
    func outboundTarget() {
        let json = """
        {"name":"ci-notify","url":"https://ci.example.com/hermes-events",
         "events":["on_session_end"],"secret_env":"HERMES_OUTBOUND_WEBHOOK_SECRET","timeout":30}
        """
        let data = json.data(using: .utf8)!
        let target = try? JSONDecoder().decode(OutboundWebhookTarget.self, from: data)
        #expect(target?.name == "ci-notify")
        #expect(target?.events == ["on_session_end"])
        #expect(target?.resolvedSecret() == nil) // env not set
        setenv("HERMES_OUTBOUND_WEBHOOK_SECRET", "s3cret", 1)
        #expect(target?.resolvedSecret() == "s3cret")
        unsetenv("HERMES_OUTBOUND_WEBHOOK_SECRET")
    }

    @Test("matcher applies to tool-scoped events")
    func matcherRule() {
        let target = OutboundWebhookTarget(
            url: "http://x", events: ["post_tool_call"], matcher: "terminal|patch"
        )
        #expect(target.matches(event: "post_tool_call", context: HookContext(["tool_name": .string("terminal")])))
        #expect(target.matches(event: "post_tool_call", context: HookContext(["tool_name": .string("patch")])))
        #expect(!target.matches(event: "post_tool_call", context: HookContext(["tool_name": .string("write_file")])))
        #expect(target.matches(event: "agent:end", context: HookContext([:])) == false)
    }

    @Test("HMAC signature is GitHub-style")
    func hmacShape() {
        let sig = HMACSHA256.hexDigest(key: "secret", data: Data("hello".utf8))
        #expect(sig.count == 64)
        // Known vector (RFC 4231 test case 2, truncated): sanity check length only.
        #expect(sig.allSatisfy { $0.isHexDigit })
    }

    @Test("blocking hook can veto")
    func blockingVeto() async {
        let bus = HookBus()
        await bus.registerBlocking("pre_tool_call") { _, ctx in
            if ctx.string("tool_name") == "terminal" {
                return .block(message: "denied by policy")
            }
            return nil
        }
        let decision = await bus.queryBlocking("pre_tool_call", ["tool_name": .string("terminal")])
        #expect(decision == .block(message: "denied by policy"))
        let allow = await bus.queryBlocking("pre_tool_call", ["tool_name": .string("read_file")])
        #expect(allow == nil)
    }
}

/// A tiny actor box for asserting across the hook consumer task (First Law:
/// no hand-rolled locks).
actor ValueBox<T> {
    private var boxed: T
    init(_ value: T) { boxed = value }
    func setValue(_ value: T) { boxed = value }
    func getValue() -> T { boxed }
}
