import Foundation
import AsyncHTTPClient
import NIOCore

/// What a reachability check found.
///
/// The question is "can a client connect and get an HTTP status", never "is the
/// model healthy": a 401 or a 404 still proves the endpoint is answering, and a
/// 5xx is the turn's own error to report.
public struct EndpointProbeResult: Sendable, Equatable {

    public enum Outcome: Sendable, Equatable {
        /// the endpoint answered with an HTTP status (`< 500` counts).
        case reachable(status: Int)
        /// the endpoint did not answer at all: refused, unroutable, or silent
        /// past the probe's deadline.
        case unreachable(detail: String)
    }

    public let endpoint: ProviderEndpoint
    public let outcome: Outcome
    public let elapsedMs: Int

    public init(endpoint: ProviderEndpoint, outcome: Outcome, elapsedMs: Int) {
        self.endpoint = endpoint
        self.outcome = outcome
        self.elapsedMs = elapsedMs
    }

    public var isReachable: Bool {
        if case .reachable = outcome { return true }
        return false
    }

    /// One line naming the endpoint and what happened — the text an error, log
    /// or notice should carry, so a failure never reads as "connection lost".
    public var detail: String {
        switch outcome {
        case .reachable(let status):
            return "HTTP \(status) from \(endpoint.baseURL.absoluteString)"
        case .unreachable(let detail):
            return "\(endpoint.baseURL.absoluteString) did not answer — \(detail)"
        }
    }
}

/// The seam a reachability check rides. Production uses ``HTTPEndpointProbe``;
/// tests and fixtures substitute their own without touching the network.
public protocol EndpointProbing: Sendable {
    func probe(_ endpoint: ProviderEndpoint, apiKey: String) async -> EndpointProbeResult
}

/// `GET <base>/models` with a short deadline — the cheapest "are you there"
/// question an OpenAI-compatible endpoint answers.
///
/// The probe is deliberately cheap rather than thorough: its job is to separate
/// "this address cannot be reached" (silence on a tunnel, a refused port) from
/// "the turn has a real request to make". A silent IPv6 peer is the case that
/// motivated it — there the TCP connect never completes, so a turn paid the
/// client's full retry cycle before reporting anything.
public struct HTTPEndpointProbe: EndpointProbing {

    /// The probe's own deadline. A metadata request that cannot answer in this
    /// window will not serve a turn either.
    public let timeout: Duration

    public init(timeout: Duration = .seconds(3)) {
        self.timeout = timeout
    }

    public func probe(_ endpoint: ProviderEndpoint, apiKey: String) async -> EndpointProbeResult {
        let started = Date()
        func elapsed() -> Int { Int(Date().timeIntervalSince(started) * 1000) }

        let url = endpoint.baseURL.appendingPathComponent("models")
        // the probe's deadline is the client's own connect bound: with a dead
        // address the TCP connect never completes, and the client's default is
        // ten seconds — a silent IPv6 peer would then cost more than the probe
        // it was meant to save.
        var configuration = HTTPClient.Configuration()
        configuration.timeout.connect = Self.timeAmount(timeout)
        configuration.timeout.read = Self.timeAmount(timeout)
        do {
            let status = try await withOneShotHTTPClient(configuration: configuration) { client -> Int in
                var request = HTTPClientRequest(url: url.absoluteString)
                request.method = .GET
                if !apiKey.isEmpty {
                    request.headers.add(name: "Authorization", value: "Bearer \(apiKey)")
                }
                let response = try await client.execute(
                    request, timeout: Self.timeAmount(timeout)
                )
                // drain a little of the body so the connection can be reused
                _ = try? await response.body.collect(upTo: 4096)
                return Int(response.status.code)
            }
            return EndpointProbeResult(
                endpoint: endpoint, outcome: .reachable(status: status), elapsedMs: elapsed()
            )
        } catch {
            return EndpointProbeResult(
                endpoint: endpoint,
                outcome: .unreachable(detail: String(describing: error)),
                elapsedMs: elapsed()
            )
        }
    }

    static func timeAmount(_ duration: Duration) -> TimeAmount {
        let parts = duration.components
        let nanoseconds = parts.seconds * 1_000_000_000 + parts.attoseconds / 1_000_000_000
        return .nanoseconds(nanoseconds)
    }
}

/// Process-wide memo of reachability, so a chatty session pays for at most one
/// probe per endpoint per window.
///
/// A **failure is never cached**: an endpoint repaired a second ago must work on
/// the very next turn, and caching "dead" is how a transient blip becomes a
/// stuck chat. Successes are cached for `ttl`, which is safe because a dead
/// endpoint invalidates itself on the next failed turn anyway.
public actor EndpointReachability {

    public static let shared = EndpointReachability()

    private var reachable: [String: (status: Int, at: Date)] = [:]
    private let ttl: TimeInterval

    public init(ttl: TimeInterval = 60) {
        self.ttl = ttl
    }

    /// Probe `endpoint`, unless a recent success makes that unnecessary.
    public func result(
        for endpoint: ProviderEndpoint,
        apiKey: String,
        probe: any EndpointProbing
    ) async -> EndpointProbeResult {
        let key = endpoint.baseURL.absoluteString
        if let hit = reachable[key], Date().timeIntervalSince(hit.at) < ttl {
            return EndpointProbeResult(
                endpoint: endpoint, outcome: .reachable(status: hit.status), elapsedMs: 0
            )
        }
        let result = await probe.probe(endpoint, apiKey: apiKey)
        switch result.outcome {
        case .reachable(let status):
            reachable[key] = (status, Date())
        case .unreachable:
            reachable[key] = nil
        }
        return result
    }

    /// Forget one endpoint's cached success.
    public func invalidate(_ endpoint: ProviderEndpoint) {
        reachable[endpoint.baseURL.absoluteString] = nil
    }

    /// Forget every cached success (tests, and a config change that may have
    /// repaired the endpoint).
    public func invalidateAll() {
        reachable.removeAll()
    }
}
