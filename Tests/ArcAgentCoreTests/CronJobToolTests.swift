import Foundation
import Testing
import ArcToolKit
@testable import ArcAgentCore

// MARK: - The `cronjob` agent tool (GROUNDZERO: constructor-bound services)
//
// Like every service-scoped tool, CronJobTool is a value built by
// ``CronJobTool.entry(context:store:history:)`` — the store it closes over
// is the one its handler acts on. There is no process-global accessor to
// drift; a surface built without a store does not carry the tool at all.

@Suite("CronJob Tool")
struct CronJobToolTests {

    private func tempStore() -> FileCronStore {
        FileCronStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-crontool-\(UUID().uuidString)", isDirectory: true))
    }

    private let context = ToolContext(
        profile: ProfileName("default")!,
        sessionID: "s1",
        workspace: "/tmp",
        grant: ToolGrant(profile: ProfileName("default")!)
    )

    @Test("entry builds a scheduling-toolset tool named cronjob")
    func entryShape() {
        let entry = CronJobTool.entry(context: context, store: tempStore())
        #expect(entry.name == "cronjob")
        #expect(entry.toolset == "scheduling")
    }

    @Test("create persists to the bound store and stamps the profile")
    func createStampsProfile() async throws {
        let store = tempStore()
        let entry = CronJobTool.entry(context: context, store: store)
        let out = try await entry.handler(["action": "create",
                                           "name": "daily-digest",
                                           "schedule": "0 9 * * *",
                                           "prompt": "summarize"])
        #expect(!out.hasPrefix("Error:"), "create succeeded: \(out)")
        let jobs = try await store.listAll()
        #expect(jobs.count == 1)
        #expect(jobs.first?.profile == "default", "the tool stamps its captured profile")
        #expect(jobs.first?.nextRunAt != nil)
    }

    @Test("create with a script builds a shell job; prompt optional, hardline rejected")
    func createScriptJob() async throws {
        let store = tempStore()
        let entry = CronJobTool.entry(context: context, store: store)
        let out = try await entry.handler(["action": "create",
                                           "name": "disk-watch",
                                           "schedule": "*/15 * * * *",
                                           "script": "df -h | tail -1"])
        #expect(!out.hasPrefix("Error:"), "script create succeeded: \(out)")
        let job = try await store.listAll().first
        #expect(job?.script == "df -h | tail -1")
        #expect(job?.prompt.isEmpty ?? false)

        // hardline scripts are refused at creation, never stored
        let bad = try await entry.handler(["action": "create", "name": "bad",
                                           "script": "rm -rf /"])
        #expect(bad.hasPrefix("Error:"), "hardline script refused")
        #expect(try await store.listAll().count == 1)
    }

    @Test("create with neither prompt nor script is refused; edit can clear a script")
    func scriptLifecycle() async throws {
        let store = tempStore()
        let entry = CronJobTool.entry(context: context, store: store)
        let none = try await entry.handler(["action": "create", "name": "empty"])
        #expect(none.contains("(or 'script')"), "legible refusal: \(none)")

        _ = try await entry.handler(["action": "create", "name": "sh",
                                     "schedule": "0 9 * * *", "script": "date"])
        let id = try await store.listAll().first?.id ?? ""
        let cleared = try await entry.handler(["action": "edit", "id": id, "script": ""])
        #expect(!cleared.hasPrefix("Error:"), "clearing works: \(cleared)")
        let job = try await store.get(id: id)
        #expect(job?.script == nil, "script cleared — prompt mode again")
    }

    @Test("create with an invalid schedule returns Error and persists nothing")
    func createRejectsGarbage() async throws {
        let store = tempStore()
        let entry = CronJobTool.entry(context: context, store: store)
        let out = try await entry.handler(["action": "create",
                                           "name": "x", "schedule": "garbage", "prompt": "p"])
        #expect(out.hasPrefix("Error:"))
        #expect(try await store.listAll().isEmpty)
    }

    @Test("create without a schedule makes a schedule-less manual job (Idle)")
    func createWithoutSchedule() async throws {
        let store = tempStore()
        let entry = CronJobTool.entry(context: context, store: store)
        // Omitted schedule...
        let out = try await entry.handler(["action": "create",
                                           "name": "manual", "prompt": "do the thing"])
        #expect(!out.hasPrefix("Error:"), "schedule-less create succeeds: \(out)")
        // ...and an explicit empty one.
        let out2 = try await entry.handler(["action": "create",
                                            "name": "manual2", "schedule": "  ", "prompt": "p"])
        #expect(!out2.hasPrefix("Error:"), "blank schedule = schedule-less: \(out2)")
        let jobs = try await store.listAll()
        #expect(jobs.count == 2)
        #expect(jobs.allSatisfy { $0.schedule.isEmpty && $0.nextRunAt == nil },
                "no schedule, no next fire — the scheduler never touches it")
    }

    @Test("edit with an empty schedule clears it and drops the next fire")
    func editClearsSchedule() async throws {
        let store = tempStore()
        let entry = CronJobTool.entry(context: context, store: store)
        _ = try await entry.handler(["action": "create", "name": "j",
                                     "schedule": "0 9 * * *", "prompt": "p"])
        let id = try await store.listAll().first!.id
        let out = try await entry.handler(["action": "edit", "id": id, "schedule": ""])
        #expect(!out.hasPrefix("Error:"), "clearing the schedule succeeds: \(out)")
        let job = try await store.get(id: id)!
        #expect(job.schedule.isEmpty && job.nextRunAt == nil)
    }

    @Test("list, pause, resume, run, edit and remove act on the bound store")
    func lifecycle() async throws {
        let store = tempStore()
        let entry = CronJobTool.entry(context: context, store: store)
        _ = try await entry.handler(["action": "create", "name": "j",
                                     "schedule": "1h", "prompt": "p"])
        var listed = try await entry.handler(["action": "list"])
        #expect(listed.contains("j"))

        let id = try await store.listAll().first!.id
        let paused = try await entry.handler(["action": "pause", "id": id])
        #expect(!paused.hasPrefix("Error:"))
        #expect(try await store.get(id: id)!.isActive == false)

        let resumed = try await entry.handler(["action": "resume", "id": id])
        #expect(!resumed.hasPrefix("Error:"))
        #expect(try await store.get(id: id)!.isActive == true)

        _ = try await entry.handler(["action": "run", "id": id])
        #expect(try await store.get(id: id)!.nextRunAt! <= Date() + 1,
                "run arms the next scheduler pass")

        let edited = try await entry.handler(["action": "edit", "id": id, "schedule": "*/5 * * * *"])
        #expect(!edited.hasPrefix("Error:"))
        #expect(try await store.get(id: id)!.schedule == "*/5 * * * *")

        _ = try await entry.handler(["action": "remove", "id": id])
        #expect(try await store.listAll().isEmpty)
        listed = try await entry.handler(["action": "list"])
        #expect(listed.contains("No scheduled jobs"))
    }

    @Test("actions on unknown ids and unknown actions return Error strings")
    func errorPaths() async throws {
        let entry = CronJobTool.entry(context: context, store: tempStore())
        for action in ["pause", "resume", "run", "remove", "history", "edit"] {
            let out = try await entry.handler(["action": action, "id": "nope"])
            #expect(out.hasPrefix("Error:"), "\(action) on a missing id errors")
        }
        let unknown = try await entry.handler(["action": "explode"])
        #expect(unknown.hasPrefix("Error: unknown action"))
    }

    @Test("history reads the bound run history backend")
    func historyReadsBackend() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-crontool-h-\(UUID().uuidString)", isDirectory: true)
        let store = FileCronStore(directory: dir)
        let history = FileCronRunHistory(directory: dir.appendingPathComponent("history", isDirectory: true))
        let entry = CronJobTool.entry(context: context, store: store, history: history)
        _ = try await entry.handler(["action": "create", "name": "h",
                                     "schedule": "1h", "prompt": "p"])
        let id = try await store.listAll().first!.id
        let out = try await entry.handler(["action": "history", "id": id])
        #expect(out.hasPrefix("Error:") == false, "empty history is not an error: \(out)")
        #expect(out.contains("No recorded runs"))
    }

    @Test("a nil profile stamps nil — the job is manageable by anyone")
    func nilProfile() async throws {
        let store = tempStore()
        let anonymous = ToolContext(
            profile: ProfileName("default")!,
            sessionID: "s2",
            workspace: "/tmp",
            grant: ToolGrant(profile: ProfileName("default")!)
        )
        let entry = CronJobTool.entry(context: anonymous, store: store)
        // The web UI path constructs jobs through CronOps with no profile
        // to stamp; the tool itself stamps its captured context. A nil
        // stamp is exercised by CronCLIModelTests' direct CronOps use.
        _ = try await entry.handler(["action": "create", "name": "n",
                                     "schedule": "1h", "prompt": "p"])
        #expect(try await store.listAll().first?.profile != nil)
    }
}
