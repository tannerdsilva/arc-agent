import Foundation

// ==========================================================================
// CardStores — store selection for the KanbanCards module.
//
// Resolved through the one storage decision every arc surface shares
// (``StoreSelection``/`storage.active`): tessera when that is the selected
// backend, the file backend otherwise (tests, CLI fallback, --tessera-off).
// ==========================================================================

public enum CardStores {
    /// Resolve the store for the current process from `~/.arc/config.json`'s
    /// `storage.active` — the same decision the session and memory stores make.
    public static func shared() async -> any CardStore {
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
