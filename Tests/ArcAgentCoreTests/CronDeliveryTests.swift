import Foundation
import Testing
@testable import ArcAgentCore

// MARK: - Platform delivery for job results (plan Phase 5)
//
// `job.deliver` is "<platform>:<chatID>" (or nil/"none"). The RUNNER does
// the sending (it owns the DeliveryManager); the SCHEDULER persists the
// outcome via the single-save rule — `lastDeliveryError` rides the same
// one `store.save(job)` as `lastOutput`, never a second publish.

@Suite("Cron Delivery")
struct CronDeliveryTests {

    // A spy adapter: records sends, optionally fails them.
    private final class SpyAdapter: PlatformAdapter, @unchecked Sendable {
        let name: String
        let shouldFail: Bool
        func run() async throws {}  // never started; a spy, not a service
        private let box = SendBox()
        init(name: String, shouldFail: Bool = false) {
            self.name = name
            self.shouldFail = shouldFail
        }
        var sent: [(platform: String, chatID: String, text: String)] {
            get async { await box.sent }
        }
        private final class SendBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _sent: [(platform: String, chatID: String, text: String)] = []
            var sent: [(platform: String, chatID: String, text: String)] {
                lock.lock(); defer { lock.unlock() }
                return _sent
            }
            func append(_ v: (platform: String, chatID: String, text: String)) {
                lock.lock(); defer { lock.unlock() }
                _sent.append(v)
            }
        }
        func send(message: OutgoingMessage, to: ChatTarget) async throws -> SendResult {
            box.append((to.platform, to.chatID, message.text))
            if shouldFail { throw TestFailure() }
            return SendResult(messageID: "m1")
        }
        var incomingMessages: AsyncStream<IncomingMessage> {
            AsyncStream { $0.finish() }
        }
    }

    struct TestFailure: Error {}

    private func tempStore() -> FileCronStore {
        FileCronStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-crondel-\(UUID().uuidString)", isDirectory: true))
    }

    private func runnerDelivering(_ spy: SpyAdapter, fail: Bool) -> @Sendable (CronJob) async throws -> CronRunResult {
        let manager = DeliveryManager()
        let adapter = spy
        return { job in
            await manager.register(adapter: adapter)
            // Mirror of the SessionHost runner's delivery section.
            var deliveryError: String?
            if let deliver = job.deliver, deliver != "none" {
                let parts = deliver.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    do {
                        _ = try await manager.send(
                            message: OutgoingMessage(text: "[cron] \(job.name)\nran", parseMode: nil, isPartial: false, attachments: nil),
                            to: ChatTarget(platform: parts[0], chatID: parts[1])
                        )
                    } catch {
                        deliveryError = "delivery failed: \(error)"
                    }
                } else {
                    deliveryError = "invalid deliver target '\(deliver)'"
                }
            }
            return CronRunResult(output: "ran", deliveryError: deliveryError)
        }
    }

    @Test("deliver grammar parses platform:chatID; nil/none send nothing")
    func grammar() {
        #expect(CronDeliveryTarget(jobDeliver: nil) == nil)
        #expect(CronDeliveryTarget(jobDeliver: "none") == nil)
        #expect(CronDeliveryTarget(jobDeliver: "telegram:123456789") == ChatTarget(platform: "telegram", chatID: "123456789"))
        #expect(CronDeliveryTarget(jobDeliver: "slack:C123,thread") == ChatTarget(platform: "slack", chatID: "C123,thread"))
        #expect(CronDeliveryTarget(jobDeliver: "no-colon") == nil)
    }

    @Test("runner with deliver target sends exactly one prefixed message")
    func sends() async throws {
        let spy = SpyAdapter(name: "telegram")
        let store = tempStore()
        var job = CronJob(name: "digest", schedule: "1h", prompt: "p")
        job.deliver = "telegram:42"
        job.nextRunAt = Date().addingTimeInterval(-1)  // due now
        try await store.save(job)
        let scheduler = CronScheduler(store: store, pollIntervalSeconds: 1, jobRunner: runnerDelivering(spy, fail: false))
        try await scheduler.runDueJobs()  // pass 1 arms nextRunAt
        try await scheduler.runDueJobs()  // pass 2 fires it
        let sends = await spy.sent
        #expect(sends.count == 1)
        #expect(sends.first?.platform == "telegram")
        #expect(sends.first?.chatID == "42")
        #expect(sends.first?.text.contains("[cron] digest") == true, "message carries the job name: \(sends.first?.text ?? "")")
        let saved = try await store.get(id: job.id)!
        #expect(saved.lastDeliveryError == nil)
        #expect(saved.lastOutput == "ran")
    }

    @Test("send failure writes lastDeliveryError and keeps lastOutput")
    func failureKeepsOutput() async throws {
        let spy = SpyAdapter(name: "telegram", shouldFail: true)
        let store = tempStore()
        var job = CronJob(name: "digest", schedule: "1h", prompt: "p")
        job.deliver = "telegram:42"
        job.nextRunAt = Date().addingTimeInterval(-1)  // due now
        try await store.save(job)
        let scheduler = CronScheduler(store: store, pollIntervalSeconds: 1, jobRunner: runnerDelivering(spy, fail: true))
        try await scheduler.runDueJobs()  // pass 1 arms nextRunAt
        try await scheduler.runDueJobs()  // pass 2 fires it
        let saved = try await store.get(id: job.id)!
        #expect(saved.lastDeliveryError != nil, "the error is persisted")
        #expect(saved.lastOutput == "ran", "the run itself succeeded")
        #expect(saved.lastStatus == "ok")
    }

    @Test("no deliver field sends nothing")
    func noDeliver() async throws {
        let spy = SpyAdapter(name: "telegram")
        let store = tempStore()
        var job = CronJob(name: "quiet", schedule: "1h", prompt: "p")
        job.nextRunAt = Date().addingTimeInterval(-1)  // due now
        try await store.save(job)
        let scheduler = CronScheduler(store: store, pollIntervalSeconds: 1, jobRunner: runnerDelivering(spy, fail: false))
        try await scheduler.runDueJobs()  // pass 1 arms nextRunAt
        try await scheduler.runDueJobs()  // pass 2 fires it
        let sends = await spy.sent
        #expect(sends.isEmpty)
        #expect(try await store.get(id: job.id)!.lastDeliveryError == nil)
    }
}
