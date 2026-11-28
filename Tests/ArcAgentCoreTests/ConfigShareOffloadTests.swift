import Foundation
import Testing

@testable import ArcAgentCore

extension ArcCoreTestRoot {

    /// The off-pool facade exists because the Argon2 derivation blocks for ~0.8 s.
    /// These prove the async path works and — the reason the executor exists —
    /// that the cooperative pool keeps running other work while a derivation is
    /// in flight.
    @Suite("config share offload", .serialized)
    struct ConfigShareOffloadTests {

        private func payload() -> ConfigSharePayload {
            ConfigSharePayload(
                preset: .init(
                    name: "offload",
                    model: "deepseek-v4-flash",
                    provider: "silva-quad",
                    baseURL: "https://api.example.com/v1",
                    apiKey: "sk-offload-test",
                    contextLength: 128_000
                ),
                createdAt: "2026-11-27T12:00:00Z"
            )
        }

        @Test("the async facade round-trips")
        func asyncRoundTrip() async throws {
            let original = payload()
            let blob = try await ConfigShareCodec.encodeOffPool(original, password: "password12")
            #expect(blob.hasPrefix("arc1e."))
            let opened = try await ConfigShareCodec.decodeOffPool(blob, password: "password12")
            #expect(opened == original)
        }

        @Test("the async facade reports a wrong passphrase as authentication failure")
        func asyncWrongPassword() async throws {
            let blob = try await ConfigShareCodec.encodeOffPool(payload(), password: "correct1234")
            await #expect(throws: ConfigShareError.authenticationFailed) {
                try await ConfigShareCodec.decodeOffPool(blob, password: "incorrect123")
            }
        }

        /// The property `ConfigShareExecutor` is bought for. A derivation is
        /// started, and while it is in flight other async work must still make
        /// progress on the cooperative pool. If the KDF ran inline, the heartbeat
        /// loop below would not tick until it finished.
        @Test("the cooperative pool keeps running while a derivation is in flight")
        func poolStaysResponsive() async throws {
            let share = payload()

            // start a derivation; do not await it yet.
            let derive = Task {
                try await ConfigShareCodec.encodeOffPool(share, password: "password12")
            }

            // tick a counter on the cooperative pool while the KDF is running.
            var ticks = 0
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(300))
            while ContinuousClock.now < deadline {
                ticks += 1
                try await Task.sleep(for: .milliseconds(5))
            }

            // the derivation is ~0.8 s, so 300 ms of ticks must have happened
            // *during* it — i.e. the pool was not blocked.
            #expect(ticks > 10, "the pool was starved: only \(ticks) ticks while the KDF ran")

            let blob = try await derive.value
            #expect(blob.hasPrefix("arc1e."))
        }
    }
}
