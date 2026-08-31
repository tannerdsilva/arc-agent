import Foundation
import NIOCore
import tessera_client

/// Errors thrown by the Tessera storage layer.
public enum TesseraStoreError: Swift.Error, CustomStringConvertible {
    /// No ``TesseraConfig`` has been configured for this process.
    case notConfigured
    /// The configured WireGuard keys are not valid 32-byte base64.
    case invalidKeys
    /// The connection has not been started.
    case notStarted
    /// Timed out waiting for the server's end-of-history markers.
    case eoseTimeout

    public var description: String {
        switch self {
        case .notConfigured:
            return "Tessera storage is not configured (set the `tessera` section in ~/.arc/config.json or ARC_TESSERA_* env vars)"
        case .invalidKeys:
            return "Tessera WireGuard keys must each be exactly 32 bytes of base64"
        case .notStarted:
            return "Tessera connection has not been started"
        case .eoseTimeout:
            return "timed out waiting for the server's end-of-history markers"
        }
    }
}

/// A single decoded event from the connection's cached model.
public struct TesseraRecord: Sendable {
    /// The NOSTR event id (also the model-storage key). Nil for records
    /// that have been written but whose echo has not yet landed.
    public let id: NOSTR_id?
    /// The `d` tag value (e.g. `arc/s/<session>/<seq>`), if the event has one.
    public let dTag: String?
    /// The event content decoded from UTF-8.
    public let content: String

    public init(id: NOSTR_id?, dTag: String?, content: String) {
        self.id = id
        self.dTag = dTag
        self.content = content
    }
}

/// A write this connection published before its echo returned from the
/// server. Merged into snapshots so reads are consistent with writes.
private struct PendingRecord {
    let id: NOSTR_id
    let kind: UInt32
    let dTag: String
    let content: String
}

/// The process-wide connection to a Tessera server.
///
/// One WireGuard tunnel serves all ARC Agent storage (sessions, memory,
/// profiles). It mirrors the role `GlobalEnvironment` played for the LMDB
/// backend: a single shared handle, opened lazily, reused for the process
/// lifetime, and closed via ``shutdown()`` at gateway teardown. Opening a
/// second tunnel to the same server under the same WireGuard identity would
/// race on the server's per-peer state, so every consumer funnels through
/// this actor.
///
/// ## Event schema
///
/// All stored data is signed NOSTR events in the non-replaceable kind band
/// (0...9,999), which needs no access level beyond a registered user. Each
/// event carries a `d` tag whose value names the record plus a GLOBAL
/// sequence number, so numbers are unique across kinds, sessions, and
/// writers:
///
/// ```
/// kind 3001  arc/s/<sessionID>/<seq>   session messages
/// kind 3002  arc/m/<key>/<seq>          memory records (key = agent|user)
/// kind 3003  arc/meta/<sessionID>/<seq> session metadata
/// kind 3004  arc/p/<name>/<seq>         profile records
/// ```
public actor TesseraConnection {

    /// The shared instance. Configure once at process start.
    public static let shared = TesseraConnection()

    // MARK: - Kinds & tags

    /// Session message events.
    public static let messageKind: UInt32 = 3_001
    /// Memory record events.
    public static let memoryKind: UInt32 = 3_002
    /// Session metadata events.
    public static let metadataKind: UInt32 = 3_003
    /// Profile record events.
    public static let profileKind: UInt32 = 3_004
    /// The prefix on every `d` tag value.
    public static let dTagPrefix = "arc/"
    /// One subscription per kind; the model receives all four.
    static let subscriptionIDs = ["arc-msgs", "arc-mem", "arc-meta", "arc-profiles"]

    // MARK: - State

    private var config: TesseraConfig?
    private var session: TesseraSession?
    private var model: ArcModel?
    private var nostrPublicKey: PublicKey?
    private var nostrPrivateKey: MemoryGuarded<RAW_ed25519.PrivateKey>?
    private var eoseTracker: EOSETracker?
    private var isStarted = false
    /// The next global sequence number to hand out.
    private var nextSeq = 0
    /// Events this client has published whose echo has not yet arrived.
    ///
    /// Reads go straight to the model, but the server's echo travels back
    /// over the tunnel asynchronously — a read issued immediately after a
    /// write would miss it. These pending records give deterministic
    /// read-after-write semantics; they are dropped once the echo lands.
    private var pendingRecords: [PendingRecord] = []

    private init() {}

    /// Whether a Tessera configuration has been provided.
    public var isConfigured: Bool { config != nil }

    // MARK: - Configuration

    /// Configure (or replace) the Tessera connection for this process.
    /// A no-op when the configuration is unchanged.
    public func configure(_ newConfig: TesseraConfig) async {
        if config == newConfig { return }
        await shutdown()
        config = newConfig
    }

    /// Tear down the connection. Safe to call on a never-started connection.
    /// Anything using the stores afterwards re-opens lazily.
    public func shutdown() async {
        if let session {
            for sub in Self.subscriptionIDs {
                try? await session.unsubscribe(subscriptionID: sub)
            }
            await session.disconnect()
        }
        session = nil
        model = nil
        nostrPrivateKey = nil
        eoseTracker = nil
        isStarted = false
        nextSeq = 0
        pendingRecords.removeAll()
    }

    // MARK: - Sequence numbers

    /// Allocate the next global sequence number.
    public func takeSequence() -> Int {
        let seq = nextSeq
        nextSeq += 1
        return seq
    }

    /// The highest sequence number found in the cached model. Used to seed
    /// the global counter so new events never collide with stored ones.
    private func globalMaxSequence() -> Int {
        guard let model else { return 0 }
        var maxSeq = 0
        for (_, event) in model.modelStorage {
            guard let dTag = findTag(tags: event.tags.array, as: DTag.self),
                  let key = Self.stringValue(dTag.value),
                  key.hasPrefix(Self.dTagPrefix),
                  let seq = Self.sequenceNumber(fromTagKey: key) else {
                continue
            }
            maxSeq = max(maxSeq, seq)
        }
        return maxSeq
    }

    /// Extracts the trailing sequence number from a `d` tag key such as
    /// `arc/s/demo/12`. Returns nil when the key has no numeric tail or the
    /// tail is not a non-negative integer (sequence numbers never go
    /// negative, and a bare number without a `/` is not a valid tag key).
    public static func sequenceNumber(fromTagKey key: String) -> Int? {
        guard key.contains("/") else { return nil }
        guard let last = key.split(separator: "/").last,
              let seq = Int(last),
              seq >= 0 else {
            return nil
        }
        return seq
    }

    // MARK: - Connection lifecycle

    /// Connect and subscribe if not already started. Idempotent.
    func ensureStarted() async throws {
        if isStarted { return }
        // Any writes tracked against a previous connection are stale once we
        // reconnect (their echoes are replayed under the fresh model).
        pendingRecords.removeAll()
        guard let config else { throw TesseraStoreError.notConfigured }
        guard let configuration = TesseraClientConfiguration(
            serverIP: config.serverIP,
            serverPort: config.serverPort,
            serverPublicKeyBase64: config.serverPublicKey,
            myPrivateKeyBase64: config.myPrivateKey
        ) else {
            throw TesseraStoreError.invalidKeys
        }

        let (publicKey, privateKey) = try RAW_ed25519.generateKeys(secretKey: configuration.myPrivateKey)
        nostrPublicKey = publicKey
        nostrPrivateKey = privateKey

        let model = ArcModel()
        let receiver = TesseraClientReceiverStore()
        receiver.models.append(model)

        let session = TesseraSession(
            client: TesseraClient(configuration: configuration),
            receiver: receiver,
            application: config.application,
            myNostrPublicKey: publicKey
        )
        let tracker = EOSETracker(expected: Self.subscriptionIDs)
        session.onEOSE = { [weak tracker] eose in
            tracker?.mark(String(eose.subscriptionID))
        }
        session.onNotice = { text in
            FileHandle.standardError.write(Data("[tessera] notice: \(text)\n".utf8))
        }
        self.model = model
        self.session = session
        self.eoseTracker = tracker

        try await session.connect()
        for (sub, kind) in zip(Self.subscriptionIDs, [Self.messageKind, Self.memoryKind, Self.metadataKind, Self.profileKind]) {
            try await session.subscribe(subscriptionID: sub, filters: [Filter(applications: [config.application], kinds: [kind])])
        }

        // Wait for every end-of-history marker, then give the receiver a
        // moment to drain the decoded events into the model.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if tracker.completed() { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        guard tracker.completed() else {
            throw TesseraStoreError.eoseTimeout
        }

        nextSeq = globalMaxSequence() + 1
        isStarted = true
    }

    // MARK: - Publishing

    /// Build, sign, and publish an event with the given kind, `d` tag value,
    /// and UTF-8 content.
    public func publish(kind: UInt32, dTagValue: String, content: String) async throws {
        guard isStarted, let session, let nostrPublicKey, let nostrPrivateKey else {
            throw TesseraStoreError.notStarted
        }
        // Sign locally so the event id is known up front: snapshots merge
        // the pending record for same-connection read consistency, and
        // `deleteAll` can still reference an event whose echo has not yet
        // landed.
        let unsigned = try UnsignedEvent(
            publicKey: nostrPublicKey,
            tags: [DTag(value: Encoded.String(dTagValue.unicodeScalars))],
            application: session.application,
            kind: kind,
            content: ByteBuffer(string: content)
        )
        let signed = try unsigned.sign(as: nostrPrivateKey)
        pendingRecords.append(PendingRecord(
            id: signed.unsignedEvent.id,
            kind: kind,
            dTag: dTagValue,
            content: content
        ))
        try await session.publish(signed)
    }

    /// Publish kind-5 deletion events for every known event whose `d` tag
    /// matches the given prefix, and drop them from the model and pending
    /// queue. Events still awaiting their echo are referenced by the id we
    /// signed locally, so the server can still apply the deletion.
    public func deleteAll(dTagPrefix prefix: String, kind: UInt32) async throws {
        guard let session, let nostrPrivateKey, var model else { return }
        var ids = model.modelStorage.compactMap { (id, event) -> NOSTR_id? in
            guard event.kind.RAW_native() == kind,
                  let dTag = findTag(tags: event.tags.array, as: DTag.self),
                  let key = Self.stringValue(dTag.value),
                  key.hasPrefix(prefix) else {
                return nil
            }
            return id
        }
        // Events we published whose echo has not landed yet.
        ids.append(contentsOf: pendingRecords
            .filter { $0.kind == kind && $0.dTag.hasPrefix(prefix) }
            .map(\.id))
        pendingRecords.removeAll { $0.kind == kind && $0.dTag.hasPrefix(prefix) }

        for id in Set(ids) {
            try? await session.delete(eventID: id, signedBy: nostrPrivateKey)
            try? model.delete(id: id)
        }
    }

    // MARK: - Reading

    /// A snapshot of every cached event of the given kind, with tags decoded.
    ///
    /// Pending (just-published, not-yet-echoed) records of this kind are
    /// merged in so reads are immediately consistent with writes; they are
    /// evicted as their echoes land in the model.
    public func snapshot(kind: UInt32) -> [TesseraRecord] {
        guard let model else { return [] }
        // Evict pending records whose echo has landed in the model.
        if !pendingRecords.isEmpty {
            let modelDTags = Set(model.modelStorage.values.compactMap { event in
                findTag(tags: event.tags.array, as: DTag.self)
                    .flatMap { Self.stringValue($0.value) }
            })
            pendingRecords.removeAll { record in
                modelDTags.contains(record.dTag)
            }
        }
        var out: [TesseraRecord] = []
        for (id, event) in model.modelStorage {
            guard event.kind.RAW_native() == kind else { continue }
            let dTag = findTag(tags: event.tags.array, as: DTag.self)
                .flatMap { Self.stringValue($0.value) }
            let content = Self.stringValue(event.content) ?? ""
            out.append(TesseraRecord(id: id, dTag: dTag, content: content))
        }
        for pending in pendingRecords where pending.kind == kind {
            out.append(TesseraRecord(id: pending.id, dTag: pending.dTag, content: pending.content))
        }
        return out
    }

    /// Reads a RAW string-like value as a Swift `String` from its bytes.
    static func stringValue(_ value: any RAW_accessible) -> String? {
        var out = ""
        value.RAW_access { buffer in
            out = String(decoding: buffer, as: UTF8.self)
        }
        return out.isEmpty ? nil : out
    }
}

// MARK: - Model

/// The concrete model the receiver decodes inbound events into. One model
/// declares all four subscription ids, so every kind lands in one storage
/// dictionary.
private final class ArcModel: TesseraModel<StringContent> {
    override init() {
        super.init()
        subscriptionIDs = TesseraConnection.subscriptionIDs
    }
}

// MARK: - EOSE tracking

/// Records which subscriptions have signalled end-of-stored-events. Updated
/// from the session's `onEOSE` callback, which fires on the connection's
/// consumer task — hence the lock.
private final class EOSETracker: @unchecked Sendable {
    private let lock = NSLock()
    private let expected: [String]
    private var seen: Set<String> = []

    init(expected: [String]) {
        self.expected = expected
    }

    func mark(_ subscriptionID: String) {
        lock.lock()
        defer { lock.unlock() }
        seen.insert(subscriptionID)
    }

    func completed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return expected.allSatisfy { seen.contains($0) }
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        seen.removeAll()
    }
}
