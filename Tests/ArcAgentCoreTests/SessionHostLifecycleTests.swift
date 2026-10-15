import Foundation
import Testing
@testable import ArcAgentCore

extension ArcCoreTestRoot {
    /// SessionHost lifecycle: the adapter `HTTPClient` must never deinit
    /// unshutdown, and must be released on both the success and failure paths
    /// of `run()`.
    @Suite("Session host lifecycle", .serialized)
    struct SessionHostLifecycleTests {

        private func makeConfig() -> SessionRegistry.AgentConfig {
            SessionRegistry.AgentConfig(
                model: "gpt-4o",
                provider: "openai",
                baseURL: "https://api.openai.com/v1",
                apiKey: "test-key",
                tessera: nil,
                persistSessions: false,
                maxIterations: 2,
                toolLoopCap: 2,
                mcpServers: [:]
            )
        }

        /// Regression: with no platform adapters configured, the shared
        /// AsyncHTTPClient used to be an unretained local — constructing (and
        /// thus releasing) the session host trapped with
        /// "Client not shut down before the deinit". The client is now created
        /// only when an adapter consumes it; constructing must not trap.
        @Test("init with no adapters does not trap on client deinit")
        func initWithoutAdapters() {
            let host = SessionHost(agentConfig: makeConfig())
            // Reference the service so the compiler keeps it alive through scope
            // exit, then release it — deinit is the regression surface.
            withExtendedLifetime(host) {}
        }
    }
}
