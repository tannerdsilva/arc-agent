import Foundation

/// A pool of API credentials for a single provider, with exhaustion tracking.
///
/// ``CredentialPool`` manages multiple API keys for the same provider and
/// distributes them round-robin. When a key is rate-limited or exhausted, it
/// is temporarily removed from rotation until a cooldown period expires.
///
/// ## Concurrency
///
/// ``CredentialPool`` is an **actor** — all access is serialized. The pool is
/// safe to share across multiple agent instances.
///
/// ## Usage
///
/// ```swift
/// let pool = CredentialPool(credentials: [
///     "sk-...", "sk-...",
/// ])
///
/// if let key = await pool.acquireLease() {
///     // use the key
///     if rateLimited {
///         await pool.reportExhaustion(key: key)
///     }
/// }
/// ```
public actor CredentialPool {

    // MARK: - Types

    /// A single credential entry in the pool.
    struct Entry: Sendable {
        let apiKey: String
        var isExhausted: Bool = false
        var exhaustedUntil: Date? = nil
    }

    // MARK: - State

    /// The credential entries.
    private var entries: [Entry]

    /// Current round-robin index.
    private var currentIndex: Int = 0

    /// Cooldown duration after a key is exhausted (default: 60 seconds).
    private let cooldownDuration: TimeInterval

    // MARK: - Init

    /// Create a credential pool.
    ///
    /// - Parameters:
    ///   - credentials: API keys to pool.
    ///   - cooldownDuration: Seconds to wait before retrying an exhausted key.
    public init(credentials: [String], cooldownDuration: TimeInterval = 60) {
        self.entries = credentials.map { Entry(apiKey: $0) }
        self.cooldownDuration = cooldownDuration
    }

    // MARK: - Public API

    /// Acquire a lease on an available credential.
    ///
    /// Returns `nil` if all credentials are exhausted.
    /// - Returns: An API key, or `nil` if none are available.
    public func acquireLease() -> String? {
        sweepExpired()

        guard !entries.isEmpty else { return nil }
        guard entries.contains(where: { !$0.isExhausted }) else { return nil }

        // Round-robin: try each entry starting from currentIndex
        for offset in 0..<entries.count {
            let idx = (currentIndex + offset) % entries.count
            if !entries[idx].isExhausted {
                currentIndex = (idx + 1) % entries.count
                return entries[idx].apiKey
            }
        }

        return nil
    }

    /// Report that a credential was exhausted (rate-limited, quota exceeded).
    ///
    /// - Parameter key: The exhausted API key.
    public func reportExhaustion(key: String) {
        guard let idx = entries.firstIndex(where: { $0.apiKey == key }) else { return }
        entries[idx].isExhausted = true
        entries[idx].exhaustedUntil = Date().addingTimeInterval(cooldownDuration)
    }

    /// Check whether any credentials are currently available.
    public func hasAvailable() -> Bool {
        sweepExpired()
        return entries.contains(where: { !$0.isExhausted })
    }

    /// The number of credentials in the pool.
    public var count: Int { entries.count }

    /// The number of currently available (non-exhausted) credentials.
    public var availableCount: Int {
        sweepExpired()
        return entries.filter { !$0.isExhausted }.count
    }

    // MARK: - Helpers

    /// Sweep expired exhaustion timers, re-enabling cooled-down keys.
    private func sweepExpired() {
        let now = Date()
        for idx in entries.indices {
            if entries[idx].isExhausted,
               let until = entries[idx].exhaustedUntil,
               until <= now
            {
                entries[idx].isExhausted = false
                entries[idx].exhaustedUntil = nil
            }
        }
    }
}
