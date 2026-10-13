import ArcSidebarTabs
import Foundation

// MARK: - Built-in sidebar tabs
//
// Every first-party tab is expressed through the same `SidebarTab`
// contract as third-party tabs: identity + rail icon flow through
// the protocol, and panel/main content are rendered by it. The heavy
// implementations remain on `AppState` (rendering plus typed wire
// functions) — the adapter simply forwards through them — so the whole
// application shell can be driven uniformly by tab id.

/// Protocol adapter for a first-party view. Created on demand by id
/// (`AppState.sidebarTab(_:)`); the actor reference is immutable, so
/// adapters are cheap and stateless.
struct BuiltInSidebarTab: SidebarTab {
    let kind: ViewID
    let state: AppState

    var id: String { kind.rawValue }
    var title: String { kind.title }
    var tooltip: String { kind.tip }
    var icon: SidebarTabIcon { .named(kind.symbolName) }

    func panelHTML() async -> String {
        await state.renderPanel(for: kind)
    }

    func mainHTML() async -> String {
        await state.renderMain(for: kind)
    }
}
