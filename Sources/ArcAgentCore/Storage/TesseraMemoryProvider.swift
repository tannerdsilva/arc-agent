import Foundation

/// A ``MemoryProvider`` backed by a Tessera server.
///
/// Memory records are signed NOSTR events (kind 3002) with `d` tags
/// `arc/m/<key>/<seq>` where `<key>` is `agent` or `user`. The content of
/// each event is the FULL current text of that memory, and reads select the
/// newest record by global sequence number — so writes are append-only at
/// the event log level while the effective value is latest-wins.
public actor TesseraMemoryProvider: MemoryProvider {

    private static let agentKey = "agent"
    private static let userKey = "user"

    /// Create a memory provider against the shared Tessera connection.
    public init() {}

    private var connection: TesseraConnection { TesseraConnection.shared }

    // MARK: - MemoryProvider

    public func readMemory() async throws -> String {
        try await read(key: Self.agentKey)
    }

    public func readUser() async throws -> String {
        try await read(key: Self.userKey)
    }

    public func appendMemory(_ text: String) async throws {
        try await append(key: Self.agentKey, text: text)
    }

    public func replaceMemory(old: String, new: String) async throws {
        try await replace(key: Self.agentKey, old: old, new: new)
    }

    public func writeMemory(_ text: String) async throws {
        try await set(key: Self.agentKey, value: text)
    }

    public func appendUser(_ text: String) async throws {
        try await append(key: Self.userKey, text: text)
    }

    public func replaceUser(old: String, new: String) async throws {
        try await replace(key: Self.userKey, old: old, new: new)
    }

    // MARK: - Private

    private func read(key: String) async throws -> String {
        let conn = connection
        try await conn.ensureStarted()
        let prefix = "arc/m/\(key)/"
        var best: (seq: Int, content: String)?
        for record in await conn.snapshot(kind: TesseraConnection.memoryKind)
            .filter({ $0.dTag?.hasPrefix(prefix) ?? false }) {
            guard let seq = TesseraConnection.sequenceNumber(fromTagKey: record.dTag ?? "") else { continue }
            if best == nil || seq > best!.seq {
                best = (seq, record.content)
            }
        }
        return best?.content ?? ""
    }

    private func append(key: String, text: String) async throws {
        let existing = try await read(key: key)
        let newContent = existing.isEmpty ? text : existing + "\n" + text
        try await set(key: key, value: newContent)
    }

    /// Overwrite the memory value with the given full text.
    private func set(key: String, value: String) async throws {
        let conn = connection
        try await conn.ensureStarted()
        let seq = await conn.takeSequence()
        try await conn.publish(
            kind: TesseraConnection.memoryKind,
            dTagValue: "arc/m/\(key)/\(seq)",
            content: value
        )
    }

    private func replace(key: String, old: String, new: String) async throws {
        let current = try await read(key: key)
        guard !current.isEmpty else { return }
        let updated = current.replacingOccurrences(of: old, with: new)
        try await set(key: key, value: updated)
    }
}
