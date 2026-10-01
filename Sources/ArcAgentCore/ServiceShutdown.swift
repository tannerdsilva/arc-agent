import ServiceLifecycle

/// Run a long-lived loop until task cancellation or the enclosing
/// ``ServiceGroup``'s graceful shutdown.
///
/// A `Service` whose `run()` ignores graceful shutdown stalls the group's
/// shutdown sequence until the grace period escalates to cancellation. Loops
/// written as `while !Task.isCancelled { … sleep … }` already exit on
/// cancellation; this wrapper turns the group's graceful shutdown into exactly
/// that cancellation, so the service stops in time instead of waiting out the
/// bound.
///
/// Cancellation — whether from the group's escalation or from a test's
/// teardown — is the expected exit, not an error: it is swallowed here so the
/// service finishes *successfully* and the group's shutdown loop can move on.
public func runUntilShutdown(
    _ operation: @Sendable @escaping () async throws -> Void
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            // returns normally on the enclosing group's graceful shutdown;
            // throws CancellationError when this service is cancelled directly.
            try await gracefulShutdown()
        }

        do {
            try await group.next()
        } catch is CancellationError {
            // expected: shutdown or cancellation
        }
        group.cancelAll()
        // drain the sibling; its CancellationError is the point, not a failure.
        while let _ = try? await group.next() {}
    }
}