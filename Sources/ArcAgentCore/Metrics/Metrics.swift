import Foundation

/// A metrics collector that tracks key performance and operational counters.
///
/// All methods are actor-isolated for thread safety. Metrics are exposed
/// as a snapshot dictionary for prometheus-style scraping.
public actor Metrics {
    public static let shared = Metrics()

    // MARK: - Counters

    private var tokensUsed: Int = 0
    private var toolsCalled: Int = 0
    private var errorsByType: [String: Int] = [:]
    private var sessionDurations: [TimeInterval] = []
    private var cacheHitRate: (hits: Int, misses: Int) = (0, 0)
    private var streamingSessions: Int = 0
    private var totalRequests: Int = 0

    // MARK: - Recording

    /// Record tokens used in a request.
    public func recordTokens(_ count: Int) {
        tokensUsed += count
    }

    /// Record a tool call.
    public func recordToolCall() {
        toolsCalled += 1
    }

    /// Record an error by type.
    public func recordError(_ type: String) {
        errorsByType[type, default: 0] += 1
    }

    /// Record a session duration in seconds.
    public func recordSessionDuration(_ seconds: TimeInterval) {
        sessionDurations.append(seconds)
        // Keep only last 1000 to bound memory
        if sessionDurations.count > 1000 {
            sessionDurations.removeFirst(sessionDurations.count - 1000)
        }
    }

    /// Record a cache hit or miss.
    public func recordCacheHit() { cacheHitRate.hits += 1 }
    public func recordCacheMiss() { cacheHitRate.misses += 1 }

    /// Record a streaming session.
    public func recordStreamingSession() { streamingSessions += 1 }

    /// Record a total request.
    public func recordRequest() { totalRequests += 1 }

    // MARK: - Snapshot

    /// Get a snapshot of all metrics as a dictionary.
    public func snapshot() -> [String: Any] {
        let totalCacheAccesses = cacheHitRate.hits + cacheHitRate.misses
        let hitRate = totalCacheAccesses > 0
            ? Double(cacheHitRate.hits) / Double(totalCacheAccesses)
            : 0.0

        let avgDuration: TimeInterval
        if sessionDurations.isEmpty {
            avgDuration = 0
        } else {
            avgDuration = sessionDurations.reduce(0, +) / Double(sessionDurations.count)
        }

        return [
            "tokens_used": tokensUsed,
            "tools_called": toolsCalled,
            "errors_by_type": errorsByType,
            "total_errors": errorsByType.values.reduce(0, +),
            "session_count": sessionDurations.count,
            "avg_session_duration_ms": Int(avgDuration * 1000),
            "cache_hit_rate": hitRate,
            "cache_hits": cacheHitRate.hits,
            "cache_misses": cacheHitRate.misses,
            "streaming_sessions": streamingSessions,
            "total_requests": totalRequests,
        ]
    }

    /// Reset all counters.
    public func reset() {
        tokensUsed = 0
        toolsCalled = 0
        errorsByType = [:]
        sessionDurations = []
        cacheHitRate = (0, 0)
        streamingSessions = 0
        totalRequests = 0
    }
}
