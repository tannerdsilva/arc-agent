import Foundation
import SwiftSlash
import Testing
@testable import ArcAgentCore

// MARK: - Verification wiring (#1)

@Suite("Verification wiring")
struct VerificationWiringTests {

    @Test("changedPaths returns git-reported changes in a repo")
    func changedPathsInGitRepo() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var initCmd = Command(absolutePath: Path("/usr/bin/git"), arguments: ["init", dir.path])
        initCmd.inheritCurrentEnvironment()
        let initOutcome = try await SubprocessRunner.runBytes(initCmd, timeout: 10)
        #expect(initOutcome.exitCode == 0)

        let file = dir.appendingPathComponent("foo.swift")
        try "let x = 1".write(to: file, atomically: true, encoding: .utf8)

        let changed = await Verification.changedPaths(in: dir.path)
        #expect(changed.contains("foo.swift"))
    }

    @Test("changedPaths is fail-open outside a git repo")
    func changedPathsNonGit() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-verify-non-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let changed = await Verification.changedPaths(in: dir.path)
        #expect(changed.isEmpty)
    }

    @Test("verifyNudge fires only past the 8-path threshold and ignores build artifacts")
    func verifyNudgeThreshold() {
        var paths = (1...9).map { "Sources/File\($0).swift" }
        #expect(!Verification.verifyNudge(changedPaths: paths).isEmpty)

        paths = (1...9).map { ".build/debug/File\($0).o" }
        #expect(Verification.verifyNudge(changedPaths: paths).isEmpty)

        paths = ["a.swift", ".build/x.o", "node_modules/y.js", "Package.resolved"]
        #expect(Verification.verifyNudge(changedPaths: paths).isEmpty)
    }

    @Test("ToolEvidence attaches the block a turn can parse")
    func evidenceAttachFormat() {
        let evidence = ToolEvidence(
            command: "swift test",
            cwd: "/tmp/x",
            exitCode: 0,
            truncated: false,
            changedPaths: ["A.swift", "B.swift"]
        )
        let result = evidence.attach(to: "ok\nexit_code: 0")
        #expect(result.contains("[evidence] command: swift test"))
        #expect(result.contains("[evidence] cwd: /tmp/x"))
        #expect(result.contains("[evidence] exit: 0"))
        #expect(result.contains("[evidence] changed paths (2): A.swift, B.swift"))
    }

    @Test("background review cadence fires at the configured interval")
    func backgroundReviewCadence() {
        let settings = BackgroundReview.Settings(afterToolCalls: 4, window: 8)
        #expect(BackgroundReview.isDue(settings: settings, totalToolCalls: 4))
        #expect(BackgroundReview.isDue(settings: settings, totalToolCalls: 8))
        #expect(!BackgroundReview.isDue(settings: settings, totalToolCalls: 3))
        let off = BackgroundReview.Settings()
        #expect(!BackgroundReview.isDue(settings: off, totalToolCalls: 4))
    }

    @Test("guidance block wraps only non-OK reviews")
    func guidanceWrapping() {
        #expect(BackgroundReview.guidanceBlock("OK") == nil)
        #expect(BackgroundReview.guidanceBlock("ok") == nil)
        #expect(BackgroundReview.guidanceBlock("") == nil)
        let g = BackgroundReview.guidanceBlock("You looped on terminal twice.")
        #expect(g == "<background-review>\nYou looped on terminal twice.\n</background-review>")
    }
}

// MARK: - Skill preprocessing gating (#3)

@Suite("Skill preprocessing wiring")
struct SkillPreprocessingGatingTests {

    @Test("templates always expand even when inline commands are off")
    func templatesExpandWithoutInline() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-skill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let content = "dir=${HERMES_SKILL_DIR} session=${HERMES_SESSION_ID}"
        let result = try await SkillPreprocessing.preprocess(
            content, skillDir: dir, sessionID: "sess-1", allowInlineCommands: false)
        #expect(result == "dir=\(dir.path) session=sess-1")
    }

    @Test("inline commands run only when allowed")
    func inlineCommandsGated() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-skill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let content = "value: !`printf hi`"
        let disabled = try await SkillPreprocessing.preprocess(
            content, skillDir: dir, sessionID: "s", allowInlineCommands: false)
        #expect(disabled == "value: !`printf hi`")

        let enabled = try await SkillPreprocessing.preprocess(
            content, skillDir: dir, sessionID: "s", allowInlineCommands: true)
        #expect(enabled == "value: hi")
    }
}

// MARK: - Session router wiring (#5)

@Suite("Session router wiring")
struct SessionRouterWiringTests {

    @Test("resolve is deterministic across router instances")
    func deterministicResolve() async {
        let chat = ChatTarget(platform: "telegram", chatID: "42", threadID: "7")
        let a = await SessionRouter().resolve(chat: chat)
        let b = await SessionRouter().resolve(chat: chat)
        #expect(a == b)
        #expect(a == "telegram:42:7")
    }

    @Test("chatTarget round-trips and remove clears the binding")
    func chatTargetRoundtrip() async {
        let router = SessionRouter()
        let chat = ChatTarget(platform: "discord", chatID: "99", threadID: nil)
        let id = await router.resolve(chat: chat)
        let round = await router.chatTarget(for: id)
        #expect(round == chat)
        await router.remove(sessionID: id)
        let after = await router.chatTarget(for: id)
        #expect(after == nil)
    }

    @Test("threaded chats get distinct sessions from the base chat")
    func threadKeying() async {
        let router = SessionRouter()
        let base = ChatTarget(platform: "slack", chatID: "1", threadID: nil)
        let threaded = ChatTarget(platform: "slack", chatID: "1", threadID: "abc")
        let baseID = await router.resolve(chat: base)
        let threadedID = await router.resolve(chat: threaded)
        #expect(baseID != threadedID)
    }
}

// MARK: - Cron scheduler wiring (#4)

actor FakeCronStore: CronStore {
    var jobs: [CronJob] = []
    var saved: [CronJob] = []

    init(jobs: [CronJob] = []) { self.jobs = jobs }

    func save(_ job: CronJob) async throws {
        if let idx = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[idx] = job
        } else {
            jobs.append(job)
        }
        saved.append(job)
    }
    func get(id: String) async throws -> CronJob? { jobs.first { $0.id == id } }
    func delete(id: String) async throws { jobs.removeAll { $0.id == id } }
    func listActive() async throws -> [CronJob] { jobs.filter { $0.isActive } }
    func listAll() async throws -> [CronJob] { jobs }
}

@Suite("Cron scheduler wiring")
struct CronSchedulerWiringTests {

    @Test("due job runs through the injected runner and stores output")
    func dueJobRuns() async throws {
        var job = CronJob(id: "j1", name: "briefing", schedule: "30m", prompt: "Summarize.")
        job.nextRunAt = Date().addingTimeInterval(-60)
        let store = FakeCronStore(jobs: [job])
        let scheduler = CronScheduler(store: store, jobRunner: { _ in "hello from cron" })

        try await scheduler.runDueJobs()

        let updated = await store.jobs.first { $0.id == "j1" }
        #expect(updated?.lastOutput == "hello from cron")
        #expect(updated?.runCount == 1)
        #expect(updated?.lastRunAt != nil)
        #expect(updated?.nextRunAt != nil)
    }

    @Test("hallucinated output cap: long runner output is truncated to 4 KB")
    func outputTruncated() async throws {
        var job = CronJob(id: "j2", name: "noise", schedule: "1d", prompt: "x")
        job.nextRunAt = Date().addingTimeInterval(-60)
        let store = FakeCronStore(jobs: [job])
        let scheduler = CronScheduler(store: store, jobRunner: { _ in String(repeating: "a", count: 9000) })
        try await scheduler.runDueJobs()
        let updated = await store.jobs.first { $0.id == "j2" }
        #expect(updated?.lastOutput?.count == 4000)
    }

    @Test("runner failure lands as Error: in lastOutput and still advances")
    func runnerFailure() async throws {
        var job = CronJob(id: "j3", name: "boom", schedule: "30m", prompt: "x")
        job.nextRunAt = Date().addingTimeInterval(-60)
        let store = FakeCronStore(jobs: [job])
        struct Boom: Error, CustomStringConvertible { var description: String { "kaput" } }
        let scheduler = CronScheduler(store: store, jobRunner: { _ in throw Boom() })
        try await scheduler.runDueJobs()
        let updated = await store.jobs.first { $0.id == "j3" }
        #expect(updated?.lastOutput?.hasPrefix("Error: ") == true)
        #expect(updated?.runCount == 1)
    }

    @Test("unparseable schedule hits the first-run bookkeeping branch")
    func firstRunBookkeeps() async throws {
        let job = CronJob(id: "j4", name: "fresh", schedule: "nonsense", prompt: "x")
        let store = FakeCronStore(jobs: [job])
        var ran = false
        let scheduler = CronScheduler(store: store, jobRunner: { _ in ran = true; return "unexpected" })
        try await scheduler.runDueJobs()
        #expect(!ran)
        let updated = await store.jobs.first { $0.id == "j4" }
        #expect(updated != nil)
        #expect(updated?.lastOutput == nil)
        #expect(updated?.runCount == 0)
    }

    @Test("computeNextRun parses human schedules including every-prefix")
    func scheduleParsing() {
        let base = Date(timeIntervalSince1970: 0)
        // every 2h → 7200s
        var job = CronJob(name: "x", schedule: "every 2h", prompt: "x")
        let next = computeNextRun(for: job) ?? .distantFuture
        #expect(abs(next.timeIntervalSinceNow - 7200) < 5)
        job = CronJob(name: "y", schedule: "30min", prompt: "x")
        let next2 = computeNextRun(for: job) ?? .distantFuture
        #expect(abs(next2.timeIntervalSinceNow - 1800) < 5)
        _ = base
    }
}

// MARK: - Config wiring (new agent keys)

@Suite("Agent config wiring")
struct AgentConfigWiringTests {

    @Test("new agent keys decode; defaults apply when absent")
    func agentKeysDecode() throws {
        let json = """
        {"agent": {"skillInlineCommands": false, "backgroundReviewAfter": 5, "backgroundReviewWindow": 3}}
        """
        let config = try JSONDecoder().decode(ArcConfig.self, from: Data(json.utf8))
        #expect(config.agent.skillInlineCommands == false)
        #expect(config.agent.backgroundReviewAfter == 5)
        #expect(config.agent.backgroundReviewWindow == 3)

        let empty = try JSONDecoder().decode(ArcConfig.self, from: Data("{}".utf8))
        #expect(empty.agent.skillInlineCommands == true)
        #expect(empty.agent.backgroundReviewAfter == 0)
        #expect(empty.agent.backgroundReviewWindow == 8)
    }
}
