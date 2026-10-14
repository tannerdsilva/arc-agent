import Foundation
import Testing
@testable import ArcWebUI

/// Session sharing (tasks 7-8). The share manager is a UI surface whose
/// AppState loads real settings on init, so — per the house pattern — the
/// pure role/grant logic is tested in ArcAgentCore and the wiring is pinned
/// against the sources here.
@Suite("Session sharing (tasks 7-8)")
struct ShareManagerTests {

    private static func source(_ name: String) -> String {
        for base in ["Sources/ArcWebUI", "Sources/ArcTheme", "Sources/ArcAgentCore/Storage"] {
            if let s = try? String(contentsOfFile: "\(base)/\(name)", encoding: .utf8) {
                return s
            }
        }
        return ""
    }

    @Test("the chat menu has a Share item wired to openSharePanel")
    func shareMenuItemWired() {
        let views = Self.source("Views.swift")
        #expect(views.contains("sm-share-"), "the session row menu must have a Share item")
        #expect(views.contains("share-badge"), "shared sessions must show a badge")
        let actions = Self.source("Actions.swift")
        #expect(actions.contains("openSharePanel(id)"),
                "sm-share must route to openSharePanel")
    }

    @Test("the share panel is rendered and its controls are wired")
    func sharePanelWired() {
        let views = Self.source("Views.swift")
        #expect(views.contains("func sharePanelHTML()"))
        #expect(views.contains("sharePanelSessionID"))
        #expect(views.contains("data-component-id=\"share-panel\""))
        #expect(views.contains("sh-rm-"))
        #expect(views.contains("share-pubkey") && views.contains("share-role"))
        let actions = Self.source("Actions.swift")
        #expect(actions.contains("func wireSharePanel"), "the share-panel wire must exist")
        #expect(actions.contains("wireSharePanel(router)"), "wireAll must install the share wire")
    }

    @Test("share state and actor methods exist on AppState")
    func shareStateAndMethods() {
        let state = Self.source("AppState.swift")
        #expect(state.contains("shareGrants"))
        #expect(state.contains("sharePanelSessionID"))
        #expect(state.contains("shareDraftPubkey"))
        #expect(state.contains("shareDraftRole"))
        #expect(state.contains("shareStaged"))
        let acts = Self.source("AppState+Actions.swift")
        #expect(acts.contains("func refreshShareGrants()"))
        #expect(acts.contains("func openSharePanel(_ id: String) async"))
        #expect(acts.contains("func saveShare"))
        #expect(acts.contains("func revokeShare"))
        #expect(acts.contains("func stageShareGrantee()"))
        #expect(acts.contains("func isSessionShared"))
        #expect(acts.contains("func identityPubkey()"))
    }

    @Test("grants are refreshed whenever sessions reload")
    func grantsRefreshedOnReload() {
        let acts = Self.source("AppState+Actions.swift")
        #expect(acts.contains("await refreshShareGrants()"),
                "session reload must refresh the share-grant cache")
    }

    @Test("the share panel and badge have theme styling")
    func shareCSS() {
        let css = Self.source("ChromeSheet.swift")
        #expect(css.contains(".share-badge"))
        #expect(css.contains(".share-card"))
        #expect(css.contains(".share-row"))
        #expect(css.contains(".share-add-row"))
    }

    @Test("share/revoke call into TesseraShareStore, gated on identity")
    func shareCallsTessera() {
        let acts = Self.source("AppState+Actions.swift")
        #expect(acts.contains("TesseraShareStore.shared.grant"))
        #expect(acts.contains("TesseraShareStore.shared.revoke"))
        #expect(acts.contains("await identityPubkey()"),
                "saveShare must not publish a grant without an owner identity")
    }
}
