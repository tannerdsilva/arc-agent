import Foundation
import Logging

/// One process-wide storage decision: the session store, the memory provider,
/// and the honest backend label.
///
/// The daemon resolves this once (Tessera probed under the same rules the CLI
/// uses) and injects the SAME pair into every consumer — the session host's
/// agents and the web UI — so no two components open a second env on the same
/// store directories. Standalone consumers (`arc chat`, the web UI shim) keep
/// resolving their own.
public struct StorageRuntime: Sendable {

    public let store: any SessionStore
    public let memory: any MemoryProvider
    /// "file" or "tessera" — the backend actually chosen.
    public let backend: String

    public init(store: any SessionStore, memory: any MemoryProvider, backend: String) {
        self.store = store
        self.memory = memory
        self.backend = backend
    }

    /// Local files: sessions under `~/.arc/sessions`, memory under `~/.arc/memories`.
    public static func file() -> StorageRuntime {
        StorageRuntime(store: FileSessionStore(), memory: FileMemoryProvider(), backend: "file")
    }

    /// Resolve process storage: Tessera when configured, not disabled, and
    /// reachable (bounded handshake); the file fallback otherwise. Configures
    /// the shared connection on the way in — callers must not configure it again.
    public static func resolve(tessera: TesseraConfig?, tesseraOff: Bool) async -> StorageRuntime {
        let logger = Logger(label: "com.arc-agent.storage")
        guard !tesseraOff, let tessera else {
            logger.warning("Storage resolved to file (guard): tesseraOff=\(tesseraOff), tesseraConfigured=\(tessera != nil)")
            return .file()
        }
        await TesseraConnection.shared.configure(tessera)
        logger.info("Tessera configured; running bounded health check")
        guard await TesseraConnection.shared.healthCheck(within: 10) else {
            logger.warning("Tessera relay unreachable (health check failed); falling back to file storage for this process")
            return .file()
        }
        logger.info("Tessera health check passed; using tessera storage")
        return StorageRuntime(
            store: TesseraSessionStore(),
            memory: TesseraMemoryProvider(),
            backend: "tessera"
        )
    }
}