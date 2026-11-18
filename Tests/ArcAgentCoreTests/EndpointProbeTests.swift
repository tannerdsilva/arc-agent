import Foundation
import Testing

@testable import ArcAgentCore

extension ArcCoreTestRoot {
    /// the reachability seam: a failure is never memoized, a success is, and a
    /// silent address is reported by name.
    @Suite("Endpoint reachability", .serialized)
    struct EndpointProbeTests {

        /// counts probes and replays a scripted answer, so the memo can be
        /// observed without touching a socket.
        private actor FakeProber: EndpointProbing {
            private(set) var calls = 0
            private let outcome: EndpointProbeResult.Outcome

            init(_ outcome: EndpointProbeResult.Outcome) {
                self.outcome = outcome
            }

            func probe(_ endpoint: ProviderEndpoint, apiKey: String) async -> EndpointProbeResult {
                calls += 1
                return EndpointProbeResult(endpoint: endpoint, outcome: outcome, elapsedMs: 1)
            }

            func callCount() -> Int { calls }
        }

        private func endpoint(_ path: String = "v1") -> ProviderEndpoint {
            ProviderEndpoint(
                baseURL: URL(string: "http://127.0.0.1:8000/\(path)")!,
                model: "m",
                provider: "p",
                source: .preset
            )
        }

        @Test("a success is served from the memo inside the window")
        func successIsMemoized() async {
            let prober = FakeProber(.reachable(status: 200))
            let memo = EndpointReachability(ttl: 60)

            let first = await memo.result(for: endpoint(), apiKey: "", probe: prober)
            let second = await memo.result(for: endpoint(), apiKey: "", probe: prober)

            #expect(first.isReachable && second.isReachable)
            #expect(await prober.callCount() == 1, "the second check must not probe again")
        }

        @Test("a failure is never memoized: a repaired endpoint works on the next turn")
        func failureIsNotCached() async {
            let prober = FakeProber(.unreachable(detail: "connect timeout"))
            let memo = EndpointReachability(ttl: 60)

            let first = await memo.result(for: endpoint(), apiKey: "", probe: prober)
            let second = await memo.result(for: endpoint(), apiKey: "", probe: prober)

            #expect(!first.isReachable && !second.isReachable)
            #expect(await prober.callCount() == 2, "a dead endpoint must be re-probed every turn")
        }

        @Test("invalidateAll forces a fresh probe")
        func invalidateForcesProbe() async {
            let prober = FakeProber(.reachable(status: 200))
            let memo = EndpointReachability(ttl: 60)

            _ = await memo.result(for: endpoint(), apiKey: "", probe: prober)
            await memo.invalidateAll()
            _ = await memo.result(for: endpoint(), apiKey: "", probe: prober)

            #expect(await prober.callCount() == 2)
        }

        @Test("the endpoint is the memo key, not the model")
        func distinctEndpointsProbeSeparately() async {
            let prober = FakeProber(.reachable(status: 200))
            let memo = EndpointReachability(ttl: 60)

            _ = await memo.result(for: endpoint("v1"), apiKey: "", probe: prober)
            _ = await memo.result(for: endpoint("v2"), apiKey: "", probe: prober)

            #expect(await prober.callCount() == 2)
        }

        @Test("the live probe reports a silent address as unreachable, naming it")
        func liveProbeOnClosedPort() async {
            // a closed loopback port refuses immediately — deterministic, and
            // the same code path a silent IPv6 peer takes after its deadline.
            let dead = ProviderEndpoint(
                baseURL: URL(string: "http://127.0.0.1:1/v1")!,
                model: "m", provider: "p", source: .preset
            )
            let result = await HTTPEndpointProbe(timeout: .milliseconds(600))
                .probe(dead, apiKey: "")

            #expect(!result.isReachable)
            #expect(result.detail.contains("http://127.0.0.1:1/v1"), "the detail must name the address")
        }

        @Test("the detail for a success is one line naming the endpoint")
        func detailText() {
            let result = EndpointProbeResult(
                endpoint: endpoint(), outcome: .reachable(status: 200), elapsedMs: 3
            )
            #expect(result.detail == "HTTP 200 from http://127.0.0.1:8000/v1")
        }

        @Test("the preflight failure is permanent, so a retry cycle cannot multiply the wait")
        func unreachableIsPermanent() {
            let error = LLMError.endpointUnreachable(
                endpoint: "http://[fdfd::1]:8000/v1", detail: "connect timeout"
            )
            #expect(classifyError(error) == .permanent)
            #expect(error.description.contains("http://[fdfd::1]:8000/v1"))
        }
    }
}
