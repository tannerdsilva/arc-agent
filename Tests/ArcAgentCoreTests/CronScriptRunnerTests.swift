import Foundation
import Testing
@testable import ArcAgentCore

// MARK: - Script jobs (`no_agent`) (plan Phase 6.2)
//
// stdout = the output; empty stdout + exit 0 = SILENT; non-zero or
// timeout = the error is the alert. Hardline scripts are rejected at
// creation — never laundered by a later approval.

@Suite("Cron Script Runner")
struct CronScriptRunnerTests {

    private func tempStore() -> FileCronStore {
        FileCronStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-script-\(UUID().uuidString)", isDirectory: true))
    }

    @Test("stdout is delivered as the run output")
    func stdoutDelivered() async throws {
        let outcome = await CronScriptRunner.run(script: "echo hello-from-script")
        #expect(outcome.failed == false)
        #expect(outcome.output == "hello-from-script")
    }

    @Test("empty stdout + exit 0 is silent")
    func silenceStaysSilent() async throws {
        let outcome = await CronScriptRunner.run(script: "true")
        #expect(outcome.failed == false)
        #expect(outcome.output == nil, "nothing to deliver: \(outcome.output ?? "?")")
    }

    @Test("failing script turns the error into the alert output")
    func failureAlerts() async throws {
        let outcome = await CronScriptRunner.run(script: "echo boom >&2; exit 3")
        #expect(outcome.failed == true)
        #expect(outcome.output?.contains("exit 3") == true)
        #expect(outcome.output?.contains("boom") == true, "stderr rides the alert")
    }

    @Test("timeout is enforced and alerts")
    func timeoutAlerts() async throws {
        let outcome = await CronScriptRunner.run(script: "sleep 30", timeoutSeconds: 1)
        #expect(outcome.failed == true)
        #expect(outcome.output?.contains("timeout") == true)
    }

    @Test("hardline script rejected at creation, not laundered later")
    func hardlineRejected() async throws {
        let store = tempStore()
        await #expect(throws: CronOpsError.self) {
            try await CronOps.create(store: store, name: "evil",
                                     schedule: "1h", prompt: "p",
                                     script: "rm -rf /")
        }
        #expect(try await store.listAll().isEmpty, "nothing persisted")
        // A benign script passes vetting and stores.
        let job = try await CronOps.create(store: store, name: "ok",
                                           schedule: "1h", prompt: "p",
                                           script: "echo tick")
        #expect(job.script == "echo tick")
        // edit can also reject — the previous script stays untouched.
        await #expect(throws: CronOpsError.self) {
            try await CronOps.edit(store: store, id: job.id, script: "mkfs /dev/sda1")
        }
        let unchanged = try await store.get(id: job.id)!
        #expect(unchanged.script == "echo tick")
    }
}
