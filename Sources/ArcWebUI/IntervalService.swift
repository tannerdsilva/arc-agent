import ArcAgentCore
import ServiceLifecycle

/// A long-lived poll loop as a `Service`.
///
/// The log stream and the workspace-tree watcher are daemon loops that must run
/// for as long as the server does. Expressing them as `Service`s keeps their
/// lifetime owned by the `ServiceGroup` instead of by ad-hoc `Task`s that
/// nothing cancels or awaits (Second Law).
struct IntervalService: Service {

    /// Label used in shutdown logging.
    let name: String

    /// Delay between ticks.
    let interval: Duration

    /// One poll. Runs on the service's task; blocking here delays the next tick.
    let tick: @Sendable () async -> Void

    init(
        name: String,
        interval: Duration,
        tick: @escaping @Sendable () async -> Void
    ) {
        self.name = name
        self.interval = interval
        self.tick = tick
    }

    func run() async throws {
        // `runUntilShutdown` converts the enclosing group's graceful shutdown
        // into task cancellation; the loop below already exits on cancellation
        // (sleep throws), so the daemon never waits out its grace period for a
        // streamer.
        try await runUntilShutdown {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                if Task.isCancelled { return }
                await tick()
            }
        }
    }
}