import ArcToolKit
import Foundation
import Logging

/// Resolves the session store + memory provider for a run, centralizing the
/// chat path's tessera-vs-file decision (reference `Arc.swift` storage block)
/// so every surface — chat, session admin commands, tools — sees the SAME
/// store. Previously the chat path and the `sessions` admin commands
/// disagreed: chats persisted to Tessera (when configured and healthy) while
/// `arc sessions list/show/delete/export/rename` unconditionally opened the
/// file store, hiding live sessions from the tooling.
///
/// ## Concurrency
/// The health check is injectable so tests can drive both branches without a
/// live relay; the production default performs the bounded Tessera handshake.
public enum SessionStoreResolver {

    /// A health check for the Tessera relay (injectable for tests).
    public typealias HealthCheck = @Sendable () async -> Bool

    /// A resolved storage pair.
    public struct Resolved: Sendable {
        public let sessionStore: any SessionStore
        public let memoryProvider: (any MemoryProvider)?
    }

    /// Resolve the storage pair the same way the chat path does.
    ///
    /// - Parameters:
    ///   - tessera: The configured Tessera block (`nil` = file storage).
    ///   - memoryDirectory: Optional per-profile memory directory (file mode).
    ///   - healthCheck: Injectable relay health check; defaults to the real
    ///     bounded Tessera handshake.
    public static func resolve(
        tessera: TesseraConfig?,
        memoryDirectory: URL? = nil,
        healthCheck: HealthCheck? = nil
    ) async -> Resolved {
        guard let tessera else {
            return Resolved(
                sessionStore: FileSessionStore(),
                memoryProvider: memoryDirectory.map { FileMemoryProvider(directory: $0) }
                    ?? FileMemoryProvider()
            )
        }

        await TesseraConnection.shared.configure(tessera)
        let healthy = await (healthCheck ?? { await TesseraConnection.shared.healthCheck() })()
        if healthy {
            return Resolved(
                sessionStore: TesseraSessionStore(),
                memoryProvider: TesseraMemoryProvider()
            )
        }

        Logger(label: "arc-agent").warning(
            "Tessera relay unreachable (handshake timed out); falling back to file storage for this run"
        )
        return Resolved(
            sessionStore: FileSessionStore(),
            memoryProvider: FileMemoryProvider()
        )
    }
}
