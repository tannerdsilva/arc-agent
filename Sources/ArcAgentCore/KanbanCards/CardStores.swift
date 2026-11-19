import Foundation
import Atomics

private final class FlagBox: Sendable {
    let value = ManagedAtomic(false)
}

// ==========================================================================
// CardStores — store selection for the KanbanCards module.
//
// Resolved through the one storage decision every arc surface shares
// (``StoreSelection``/`storage.active`): tessera when that is the selected
// backend, the file backend otherwise (tests, CLI fallback, --tessera-off).
//
// When the tessera backend is selected AND the daemon's HTTP API is
// reachable (token present, `~/.arc/.env`), a non-daemon process returns a
// ``ProxiedCardStore`` instead of a direct ``TesseraCardStore``: every
// card verb — context resolution, tool calls, result writes — then executes
// on the daemon's own tunnel, and the process never opens a second tunnel
// under the same WireGuard static key (the peer-index roam that resets the
// other process's KCP control block). If the daemon is NOT reachable, the
// proxied store falls back to the local backend per call, so a standalone
// CLI or worker still makes its own tunnel and works unchanged.
// ==========================================================================

public enum CardStores {
    /// Set once at daemon boot (``SessionHost`` init): a daemon process
    /// never proxies — its own store resolution would loop back through
    /// its own HTTP server. Write-once before any store resolution happens.
    private static let flag = FlagBox()
    public static var isDaemonProcess: Bool {
        get { flag.value.load(ordering: .relaxed) }
        set { flag.value.store(newValue, ordering: .relaxed) }
    }

    /// Resolve the store for the current process from `~/.arc/config.json`'s
    /// `storage.active` — the same decision the session and memory stores make.
    public static func shared() async -> any CardStore {
        let selection = StoreSelection.resolve(loadConfig())
        // Proxy only when the daemon could actually be running: a live
        // HTTP token AND the tessera backend (file backends have no
        // tunnel to share).
        if !isDaemonProcess, selection.backend == .tessera, selection.tessera != nil,
           let proxy = KanbanProxy.resolve() {
            return ProxiedCardStore(host: proxy.host, port: proxy.port, token: proxy.token)
        }
        return await localBackend()
    }

    /// The process's own direct backend — the tunnel-opening path. Used as
    /// the proxied store's fallback and by daemon processes.
    public static func localBackend() async -> any CardStore {
        let selection = StoreSelection.resolve(loadConfig())
        switch selection.backend {
        case .tessera where selection.tessera != nil:
            await TesseraConnection.shared.configure(selection.tessera!)
            return TesseraCardStore()
        default:
            return FileCardStore()
        }
    }
}
