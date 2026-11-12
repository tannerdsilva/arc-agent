import Foundation
import Testing
import ArcToolKit
@testable import ArcAgentCore

// MARK: - Per-job workspace + model pins (create/edit/tool/codable)

@Suite("Cron Workspace Model")
struct CronWorkspaceModelTests {

    private func tempStore() -> FileCronStore {
        FileCronStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-wsmodel-\(UUID().uuidString)", isDirectory: true))
    }

    private func tempDirectory() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-wsmodel-dir-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    @Test("create stores an existing workspace and model; nonexistent workspace is rejected")
    func createValidation() async throws {
        let store = tempStore()
        let dir = tempDirectory()
        let job = try await CronOps.create(
            store: store, name: "j", schedule: "1h", prompt: "p",
            workspace: dir, model: "test-model-x")
        #expect(job.workspace == dir)
        #expect(job.model == "test-model-x")

        let stored = try await store.get(id: job.id)!
        #expect(stored.workspace == dir)
        #expect(stored.model == "test-model-x")

        await #expect(throws: CronOpsError.self) {
            _ = try await CronOps.create(
                store: store, name: "bad", schedule: "1h", prompt: "p",
                workspace: "/nonexistent/\(UUID().uuidString)")
        }
    }

    @Test("workspace tilde expands and blank input normalizes to nil")
    func normalization() {
        let expanded = CronOps.normalizedWorkspace("  ~/arc-ws  ")
        #expect(expanded?.hasPrefix("/") == true)
        #expect(!expanded!.contains("~"))
        #expect(CronOps.normalizedWorkspace("   ") == nil)
        #expect(CronOps.normalizedWorkspace(nil) == nil)
        #expect(CronOps.normalizedWorkspace("   ") == nil)
    }

    @Test("edit sets and clears both fields; absent params leave them untouched")
    func editSemantics() async throws {
        let store = tempStore()
        let dir = tempDirectory()
        let job = try await CronOps.create(
            store: store, name: "j", schedule: "1h", prompt: "p",
            workspace: dir, model: "m1")

        // Absent params: untouched.
        var edited = try await CronOps.edit(store: store, id: job.id, name: "j2")
        #expect(edited.workspace == dir)
        #expect(edited.model == "m1")

        // Empty string clears; presence semantics (String??).
        edited = try await CronOps.edit(store: store, id: job.id, name: nil,
                                        schedule: nil, prompt: nil, deliver: nil,
                                        script: nil, resetEveryRuns: nil,
                                        contextFrom: nil, runBudget: nil,
                                        workspace: "", model: "")
        #expect(edited.workspace == nil, "empty string clears the workspace")
        #expect(edited.model == nil, "empty string clears the model")

        // Setting a nonexistent workspace via edit throws and leaves the job alone.
        await #expect(throws: CronOpsError.self) {
            _ = try await CronOps.edit(store: store, id: job.id, name: nil,
                                       schedule: nil, prompt: nil, deliver: nil,
                                       script: nil, resetEveryRuns: nil,
                                       contextFrom: nil, runBudget: nil,
                                       workspace: "/nonexistent/\(UUID().uuidString)")
        }
        let untouched = try await store.get(id: job.id)!
        #expect(untouched.workspace == nil)
    }

    @Test("workspace/model survive the JSON round trip and decode from records without them")
    func codableRoundTrip() throws {
        var job = CronJob(name: "j", schedule: "1h", prompt: "p")
        job.workspace = "/tmp/ws"
        job.model = "test-model-y"
        let data = try JSONEncoder().encode(job)
        let back = try JSONDecoder().decode(CronJob.self, from: data)
        #expect(back.workspace == "/tmp/ws")
        #expect(back.model == "test-model-y")

        // Old persisted records (no keys) decode to nil, not throw.
        let legacy = try JSONDecoder().decode(
            CronJob.self, from: try JSONEncoder().encode(CronJob(name: "old", schedule: "", prompt: "p")))
        #expect(legacy.workspace == nil)
        #expect(legacy.model == nil)
    }

    @Test("cronjob tool create/edit accept workspace and model args")
    func toolArgs() async throws {
        let store = tempStore()
        let dir = tempDirectory()
        let context = ToolContext(
            profile: ProfileName("default")!,
            sessionID: "s1",
            workspace: "/tmp",
            grant: ToolGrant(profile: ProfileName("default")!)
        )
        let entry = CronJobTool.entry(context: context, store: store)

        let created = try await entry.handler([
            "action": "create", "name": "t", "prompt": "p", "schedule": "1h",
            "workspace": dir, "model": "test-model-z",
        ])
        #expect(!created.hasPrefix("Error:"), "\(created)")
        let jobs = try await store.listAll()
        #expect(jobs.count == 1)
        #expect(jobs.first?.workspace == dir)
        #expect(jobs.first?.model == "test-model-z")

        let edited = try await entry.handler([
            "action": "edit", "id": jobs.first!.id, "workspace": "", "model": "",
        ])
        #expect(!edited.hasPrefix("Error:"), "\(edited)")
        let after = try await store.get(id: jobs.first!.id)!
        #expect(after.workspace == nil, "empty string clears via the tool")
        #expect(after.model == nil)

        let rejected = try await entry.handler([
            "action": "edit", "id": jobs.first!.id, "workspace": "/nonexistent/\(UUID().uuidString)",
        ])
        #expect(rejected.hasPrefix("Error:"))
    }
}
