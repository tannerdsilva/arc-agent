import Testing
import AsyncHTTPClient

@testable import ArcAgentCore

/// the one-shot client lifecycle: `withOneShotHTTPClient` must leave no live
/// client behind on either exit.
///
/// this is the regression pin for the crash class where an `AsyncHTTPClient`
/// client is released without `shutdown()` — the dependency traps in its deinit
/// in debug builds (`Fatal error: Client not shut down before the deinit`), which
/// is what Ctrl-C on `arc serve` hit. The proof is the release itself: each test
/// holds the helper's client, then drops it, so a helper that skipped the
/// shutdown aborts the suite loudly instead of passing silently.
@Suite("HTTP client lifecycle", .serialized)
struct HTTPClientLifecycleTests {

    /// Holds the client under test so the release is deterministic — a client
    /// dropped inside the closure could be deallocated on another executor.
    nonisolated(unsafe) private static var released: HTTPClient?

    private struct Boom: Error {}

    @Test("a one-shot success returns the value and leaves no live client")
    func successReleasesTheClient() async throws {
        let value = try await withOneShotHTTPClient { client -> Int in
            Self.released = client
            return 41
        }
        #expect(value == 41)
        // traps here if the helper returned with the client still up
        Self.released = nil
    }

    @Test("a one-shot failure propagates and leaves no live client")
    func failureReleasesTheClient() async {
        await #expect(throws: Boom.self) {
            try await withOneShotHTTPClient { client -> Int in
                Self.released = client
                throw Boom()
            }
        }
        // the error path is the one a `try?`-swallowing cleanup forgets
        Self.released = nil
    }
}