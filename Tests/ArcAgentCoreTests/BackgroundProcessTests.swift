import Foundation
import Testing
@testable import ArcAgentCore

/// Hermes `terminal(background=true)` + `process` collect parity: start a
/// detached run, work around it, then poll/log/wait/kill.
@Suite("Background process registry")
struct BackgroundProcessTests {

    @Test("start + wait + log: output captured, exit code recorded")
    func collectCompletedRun() async throws {
        let reg = ProcessRegistry.shared
        let id = try await reg.start(
            command: "echo hello-bg; sleep 0.4; echo done-bg",
            workdir: FileManager.default.homeDirectoryForCurrentUser.path
        )
        let snap = await reg.wait(id: id, timeout: 15)
        #expect(snap != nil)
        #expect(snap?.status == "exited")
        #expect(snap?.exitCode == 0)
        #expect(snap?.completionReason == "exited")
        #expect(snap?.output.contains("hello-bg") == true)
        #expect(snap?.output.contains("done-bg") == true)

        let full = await reg.log(id: id)
        #expect(full?.output.contains("hello-bg") == true)
    }

    @Test("poll reports running before exit and exited after")
    func pollTransitions() async throws {
        let reg = ProcessRegistry.shared
        let id = try await reg.start(command: "sleep 1")
        let early = await reg.poll(id: id)
        #expect(early?.status == "running")
        _ = await reg.wait(id: id, timeout: 15)
        let late = await reg.poll(id: id)
        #expect(late?.status == "exited")
    }

    @Test("list surfaces the session with status")
    func listSessions() async throws {
        let reg = ProcessRegistry.shared
        let id = try await reg.start(command: "echo listed-\(UUID().uuidString.prefix(4)); sleep 0.1")
        _ = await reg.wait(id: id, timeout: 15)
        let all = await reg.summaries()
        #expect(all.contains { ($0["session_id"] as? String) == id })
        let entry = all.first { ($0["session_id"] as? String) == id }
        #expect(entry?["status"] as? String == "exited")
    }

    @Test("kill terminates a long run and records killed")
    func killTerminates() async throws {
        let reg = ProcessRegistry.shared
        let id = try await reg.start(command: "sleep 30")
        let before = await reg.poll(id: id)
        #expect(before?.status == "running")
        let after = await reg.kill(id: id)
        #expect(after?.status == "exited")
        #expect(after?.completionReason == "killed")
    }

    @Test("unknown session id yields an error through the tool handler")
    func unknownSession() async throws {
        let result = try await ProcessTool.handle(["action": "poll", "session_id": "nope-123"])
        #expect(result.contains("unknown session_id"))
        let badAction = try await ProcessTool.handle(["action": "explode"])
        #expect(badAction.contains("Unknown process action"))
        let missing = try await ProcessTool.handle(["action": "wait"])
        #expect(missing.contains("session_id is required"))
    }

    @Test("process tool is registered beside terminal in the default registry")
    func registryWiring() async throws {
        let registry = try ArcAgentCore.buildDefaultRegistry()
        #expect(registry.lookup(name: "process") != nil)
        #expect(registry.lookup(name: "process")?.toolset == "terminal")
        #expect(registry.lookup(name: "terminal") != nil)
    }
}
