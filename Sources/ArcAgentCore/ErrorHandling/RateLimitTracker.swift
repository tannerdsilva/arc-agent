import Foundation

/// Rate-limit tracking (Hermes `rate_limit_tracker.py`): captures bucket
/// state from provider headers, computes backoff honoring `Retry-After`,
/// and reports usage percentages for the next retry decision.
public actor RateLimitTracker {

    public struct Bucket: Sendable {
        public let limit: Int?
        public let remaining: Int?
        public let resetSeconds: Double?
        public let resetAt: Date?
        public let usedPercent: Double?
        public let capturedAt: Date
    }

    /// In-memory buckets per provider/model (Hermes keeps a per-route dict).
    private var buckets: [String: Bucket] = [:]
    /// Consecutive 429s seen per route (Hermes counts for backoff growth).
    private var consecutiveThrottles: [String: Int] = [:]
    public static let maxBackoffSeconds = 120.0

    public init() {}

    /// Record a bucket snapshot captured from response headers.
    public func record(_ snapshot: WireTransport.RateLimitSnapshot?, route: String, retryAfter: Int?) {
        guard let snapshot else {
            // Only retry-after was present (no bucket): still record route
            // backoff state.
            if let retryAfter {
                consecutiveThrottles[route, default: 0] += 1
            }
            return
        }
        buckets[route] = Bucket(
            limit: snapshot.limit,
            remaining: snapshot.remaining,
            resetSeconds: snapshot.resetSeconds,
            resetAt: snapshot.resetAt,
            usedPercent: snapshot.usedPercent,
            capturedAt: Date()
        )
        if retryAfter != nil { consecutiveThrottles[route, default: 0] += 1 }
    }

    /// Record a throttle event (429 response) for a route.
    public func recordThrottle(route: String, retryAfter: Int?) {
        consecutiveThrottles[route, default: 0] += 1
        if let retryAfter {
            buckets[route] = Bucket(
                limit: nil, remaining: nil,
                resetSeconds: Double(retryAfter),
                resetAt: Date().addingTimeInterval(TimeInterval(retryAfter)),
                usedPercent: nil, capturedAt: Date()
            )
        }
    }

    /// Reset the consecutive-throttle counter for a route after success.
    public func recordSuccess(route: String) {
        consecutiveThrottles[route] = 0
    }

    /// Backoff to wait before the next request on this route:
    /// retry-after when present (jittered, capped), else exponential growth
    /// from the 429 streak (Hermes `parse_retry_after_seconds` + growth).
    public func backoffSeconds(route: String) -> Double {
        guard let bucket = buckets[route],
              let resetSeconds = bucket.resetSeconds else {
            let streak = consecutiveThrottles[route] ?? 0
            return min(pow(2.0, Double(streak)) * 2.0, Self.maxBackoffSeconds)
        }
        // Honor the server's remaining wait, jittered to avoid synchronized
        // retries, capped.
        let jittered = resetSeconds * Double.random(in: 0.9...1.1)
        return min(max(jittered, 0), Self.maxBackoffSeconds)
    }

    /// How much of the bucket has been consumed (0-100%), nil when unknown.
    public func usagePercent(route: String) -> Double? {
        buckets[route]?.usedPercent
    }

    public func bucket(route: String) -> Bucket? {
        buckets[route]
    }

    public func throttleStreak(route: String) -> Int {
        consecutiveThrottles[route] ?? 0
    }
}

/// Human-readable usage line for the report surface (Hermes
/// `render_rate_limit_status` style).
public enum RateLimitRenderer {
    public static func statusLine(tracker: RateLimitTracker, route: String) async -> String {
        guard let bucket = await tracker.bucket(route: route) else { return "" }
        if let limit = bucket.limit, let remaining = bucket.remaining {
            return "Rate limit: \(remaining)/\(limit) remaining"
        }
        return "Rate limit: \(bucket.usedPercent.map { String(format: "%.0f%%", $0) } ?? "?") used"
    }
}
