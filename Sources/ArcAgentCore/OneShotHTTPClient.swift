import AsyncHTTPClient

/// Run `body` with a fresh one-shot ``HTTPClient``, shutting that client down on
/// every exit — success or throw.
///
/// `AsyncHTTPClient` traps in its deinit when the client was never shut down
/// (`Fatal error: Client not shut down before the deinit`), and `defer` cannot
/// await. A `defer { Task { try? await client.shutdown() } }` does not fix it
/// either: the caller returns — and the process may exit — before that
/// unstructured task ever runs, so the client can still be deinitialized open.
///
/// This is for one-shot callers (a single request, a CLI subcommand). A
/// long-lived owner keeps its client as state and shuts it down at the end of
/// its `run()` — cleanup belongs to the service, never to a `deinit`.
public func withOneShotHTTPClient<T>(
    _ body: (HTTPClient) async throws -> T
) async throws -> T {
    let client = HTTPClient(eventLoopGroupProvider: .singleton)
    do {
        let result = try await body(client)
        try? await client.shutdown()
        return result
    } catch {
        try? await client.shutdown()
        throw error
    }
}