import Foundation

/// An LRU cache of agent instances with idle TTL eviction.
///
/// The cache holds active ``ArcAgent`` instances keyed by session ID.
/// Entries are evicted when:
/// - The cache exceeds its maximum size (LRU entry is evicted)
/// - An entry has been idle longer than the configured TTL
///
/// Thread safety is provided by the actor isolation.
public actor AgentCache {
    private struct Entry {
        let agent: ArcAgent
        let createdAt: ContinuousClock.Instant
        var lastUsedAt: ContinuousClock.Instant
    }

    private var cache: [String: Entry] = [:]
    private var accessOrder: [String] = []
    private let maxSize: Int
    private let idleTTL: Duration

    /// Create an agent cache.
    /// - Parameters:
    ///   - maxSize: Maximum number of agents to cache (default: 100).
    ///   - idleTTL: How long an agent can sit idle before eviction (default: 30 minutes).
    public init(maxSize: Int = 100, idleTTL: Duration = .seconds(1800)) {
        self.maxSize = maxSize
        self.idleTTL = idleTTL
    }

    /// Get an existing agent or create a new one via the factory.
    public func getOrCreate(sessionID: String, factory: () async -> ArcAgent) async -> ArcAgent {
        let now = ContinuousClock.now

        // Hit — refresh LRU order and last-used time
        if var entry = cache[sessionID] {
            entry.lastUsedAt = now
            cache[sessionID] = entry
            touch(sessionID)
            return entry.agent
        }

        // Miss — create via factory
        let agent = await factory()
        cache[sessionID] = Entry(agent: agent, createdAt: now, lastUsedAt: now)
        touch(sessionID)

        // Evict if over capacity
        if cache.count > maxSize {
            evictLRU()
        }

        return agent
    }

    /// Evict a specific session from the cache.
    public func evict(sessionID: String) {
        cache.removeValue(forKey: sessionID)
        accessOrder.removeAll { $0 == sessionID }
    }

    /// Sweep idle entries, evicting any that have exceeded the idle TTL.
    public func sweepIdle() {
        let now = ContinuousClock.now
        let staleIDs = cache.compactMap { (id, entry) -> String? in
            let elapsed = now - entry.lastUsedAt
            return elapsed >= idleTTL ? id : nil
        }
        for id in staleIDs {
            cache.removeValue(forKey: id)
            accessOrder.removeAll { $0 == id }
        }
    }

    /// The number of cached agents.
    public var count: Int { cache.count }

    // MARK: - Private

    private func touch(_ id: String) {
        accessOrder.removeAll { $0 == id }
        accessOrder.append(id)
    }

    private func evictLRU() {
        guard let lru = accessOrder.first else { return }
        cache.removeValue(forKey: lru)
        accessOrder.removeFirst()
    }
}
