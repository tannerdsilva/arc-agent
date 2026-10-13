import Foundation
import Logging
import ServiceLifecycle
import Testing

@testable import ArcAgentCore

/// The shutdown contract behind ``runUntilShutdown``: a loop that only watches
/// `Task.isCancelled` must still finish when the enclosing group is gracefully
/// shut down — that is the bridge SIGTERM relies on.
@Suite("Service shutdown")
struct ServiceShutdownTests {

    /// Records that the loop exited.
    private actor ExitFlag {
        private(set) var stopped = false
        func stop() { stopped = true }
    }

    /// A service whose run() is a cancellation-watching loop wrapped in
    /// `runUntilShutdown` — the shape every daemon leaf now has.
    private struct LoopingService: Service {
        let flag: ExitFlag

        func run() async throws {
            try await runUntilShutdown {
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            await flag.stop()
        }
    }

    @Test("a wrapped loop finishes on the group's graceful shutdown")
    func gracefulShutdownEndsWrappedLoop() async throws {
        let flag = ExitFlag()
        let group = ServiceGroup(
            configuration: ServiceGroupConfiguration(
                services: [LoopingService(flag: flag)],
                logger: Logger(label: "test.service-shutdown")
            )
        )

        let groupTask = Task { try await group.run() }
        // let the loop start, then ask the group to stop the way SIGTERM would.
        try await Task.sleep(for: .milliseconds(50))
        await group.triggerGracefulShutdown()

        var stopped = false
        for _ in 0..<50 {
            if await flag.stopped {
                stopped = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(stopped, "the loop never observed the group's graceful shutdown")
        try await groupTask.value
    }
}