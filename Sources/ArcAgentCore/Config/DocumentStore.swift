import Foundation
import Logging

/// A document the shared store can own.
///
/// One store serves `config.json` and `settings.json`: the guarantees below are
/// the same for both, so they live in one generic actor rather than being
/// copied per file.
public protocol ConfigurationDocument: Codable, Equatable, Sendable {
    /// The file this document lives in when the caller supplies no URL.
    static var defaultURL: URL { get }

    /// The value a **missing** file stands for (compiled defaults).
    ///
    /// Never used for an unreadable file: that is a ``ConfigError/parseError``
    /// and makes the store read-only until the file is fixed.
    static var defaultValue: Self { get }
}

extension ArcConfig: ConfigurationDocument {
    public static var defaultURL: URL { ArcHome.config }
    public static var defaultValue: ArcConfig { ArcConfig() }
}

/// The single door to one JSON document on disk.
///
/// Every process that reads or writes the document goes through one store. The
/// store owns the guarantees that were previously spread across `loadConfig()`
/// and `saveConfig` call sites — and, for `settings.json`, were missing:
///
/// 1. **One write path.** ``mutate(_:)`` is the only way the document changes.
///    It takes the declared document, applies the edit, writes atomically,
///    decodes the bytes it wrote, and only then publishes.
/// 2. **No silent clobber.** If the file on disk cannot be decoded, the store
///    records the failure and *refuses* writes. Reading a corrupt file as
///    "defaults" meant the next toggle wrote a full default document over the
///    user's file.
/// 3. **Declared vs resolved.** ``declared`` is what the file says (what a
///    write edits); ``resolved`` is what this process runs with (file +
///    environment). The UI writes declared and renders resolved, so an env
///    override is never baked back into the file.
/// 4. **One generation of backup.** Before an existing, decodable file is
///    replaced it is copied to `<url>.bak` — the recovery path for state that
///    is too valuable to lose to one bad write.
///
/// The store knows nothing about any one document's shape: environment
/// resolution and the write strategy are injected. `DocumentStore<ArcConfig>`
/// resolves environment overrides and writes through `saveConfig` (secrets to
/// `.env`); `DocumentStore<AppSettings>` is the identity resolution.
public actor DocumentStore<Document: ConfigurationDocument> {

    /// One consistent view of the document at a point in time.
    public struct Snapshot: Sendable, Equatable {
        /// The file's contents, before environment overrides.
        public let declared: Document
        /// The document this process runs with (declared + environment).
        public let resolved: Document
        /// The file the store reads and writes.
        public let url: URL

        public init(declared: Document, resolved: Document, url: URL) {
            self.declared = declared
            self.resolved = resolved
            self.url = url
        }
    }

    private let url: URL
    private let environment: [String: String]
    private let resolve: @Sendable (Document, [String: String]) -> Document
    private let writeDocument: @Sendable (Document, URL) throws -> Void
    private var snapshotValue: Snapshot
    /// Non-nil when the file exists but cannot be decoded. Writes are refused
    /// until the file is fixed (or removed), so a bad edit can never be
    /// replaced by compiled defaults.
    private var loadFailure: ConfigError?
    private var subscribers: [UUID: AsyncStream<Snapshot>.Continuation] = [:]

    /// - Parameters:
    ///   - url: the document file. Defaults to ``ConfigurationDocument/defaultURL``.
    ///   - environment: the environment overrides are read from. Injected so
    ///     tests never depend on the ambient process environment.
    ///   - resolve: the environment overlay for this document (identity when it
    ///     has no environment surface).
    ///   - write: the encoding/write strategy for this document. Defaults to
    ///     ``write(_:to:)`` (JSON, atomic, with the written bytes decoded back
    ///     before the write returns).
    public init(
        url: URL = Document.defaultURL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resolve: @escaping @Sendable (Document, [String: String]) -> Document,
        write: @escaping @Sendable (Document, URL) throws -> Void = { document, url in
            try DocumentStore<Document>.write(document, to: url)
        }
    ) {
        self.url = url
        self.environment = environment
        self.resolve = resolve
        self.writeDocument = write
        var declared = Document.defaultValue
        var failure: ConfigError?
        do {
            declared = try DocumentStore<Document>.read(url)
        } catch let error as ConfigError {
            failure = error
            // keep the log line the old loader emitted: a silent discard here
            // means every stored choice is ignored.
            Logger(label: "com.arc-agent.config").error(
                "Failed to parse \(url.path); the document is read-only until it is fixed: \(error)"
            )
        } catch {
            failure = .parseError(String(describing: error))
        }
        self.loadFailure = failure
        self.snapshotValue = Snapshot(
            declared: declared,
            resolved: resolve(declared, environment),
            url: url
        )
    }

    // MARK: - Reading

    /// The current snapshot.
    public func snapshot() -> Snapshot { snapshotValue }

    /// The declaration (file contents, no environment overrides).
    public func declared() -> Document { snapshotValue.declared }

    /// The document this process runs with.
    public func resolved() -> Document { snapshotValue.resolved }

    /// The decode failure that makes this store read-only, if any.
    public func failure() -> ConfigError? { loadFailure }

    /// Re-read the file (an external `arc config` edit, a hand edit).
    ///
    /// Returns the published snapshot. A file that no longer decodes marks the
    /// store read-only instead of discarding the last good declaration.
    @discardableResult
    public func reload() -> Snapshot {
        do {
            let declared = try DocumentStore<Document>.read(url)
            loadFailure = nil
            snapshotValue = Snapshot(
                declared: declared,
                resolved: resolve(declared, environment),
                url: url
            )
        } catch let error as ConfigError {
            loadFailure = error
        } catch {
            loadFailure = .parseError(String(describing: error))
        }
        publish(snapshotValue)
        return snapshotValue
    }

    // MARK: - Writing

    /// Apply one edit and persist it. The only write path.
    ///
    /// - Parameter body: the mutation, applied to the declared document.
    /// - Throws: ``ConfigError`` when the file is unreadable (see
    ///   ``failure()``) or when the write/round-trip fails. On a throw the
    ///   in-memory snapshot is unchanged and nothing was published.
    @discardableResult
    public func mutate(_ body: @Sendable (inout Document) throws -> Void) throws -> Snapshot {
        if let loadFailure { throw loadFailure }
        var next = snapshotValue.declared
        try body(&next)
        // refuse a no-op write: nothing changed, nothing published.
        guard next != snapshotValue.declared else { return snapshotValue }
        try writeDocument(next, url)
        // prove the bytes we wrote decode back to what we meant before any
        // reader sees the new value.
        let verified = try DocumentStore<Document>.read(url)
        snapshotValue = Snapshot(
            declared: verified,
            resolved: resolve(verified, environment),
            url: url
        )
        publish(snapshotValue)
        return snapshotValue
    }

    // MARK: - Observation

    /// A stream of every snapshot this store publishes.
    ///
    /// The stream finishes when its consumer cancels or the continuation is
    /// dropped; a subscriber never keeps the store alive.
    public func updates() -> AsyncStream<Snapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Snapshot>.makeStream()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    private func publish(_ snapshot: Snapshot) {
        for continuation in subscribers.values {
            continuation.yield(snapshot)
        }
    }

    // MARK: - Pure file helpers (shared with `loadConfig` / `loadSettings`)

    /// Read and decode the document.
    ///
    /// A missing file is ``ConfigurationDocument/defaultValue`` (compiled
    /// defaults); a file that exists but does not decode is a
    /// ``ConfigError/parseError`` — never a silent fall back to defaults.
    public static func read(_ url: URL) throws -> Document {
        guard FileManager.default.fileExists(atPath: url.path) else { return Document.defaultValue }
        do {
            return try JSONDecoder().decode(Document.self, from: try Data(contentsOf: url))
        } catch {
            throw ConfigError.parseError("\(url.path): \(error)")
        }
    }

    /// Copy an existing, decodable file to `<url>.bak`.
    ///
    /// Throws when the file exists but does not decode: a file we cannot read
    /// is never replaced, and therefore never backed up over a good `.bak`.
    public static func backup(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        _ = try read(url)
        let backupURL = url.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backupURL)
        try FileManager.default.copyItem(at: url, to: backupURL)
    }

    /// Write the document: one-generation backup, atomic replace, decode-back.
    public static func write(_ document: Document, to url: URL) throws {
        try backup(at: url)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: url, options: .atomic)
        // prove the bytes we wrote decode before any reader sees the new
        // value (a document whose decode migrates legacy fields need not
        // round-trip to an equal value — `AppSettings` renames a scheme).
        _ = try read(url)
    }
}
