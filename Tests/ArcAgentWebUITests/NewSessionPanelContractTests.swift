import Foundation
import Testing
@testable import ArcWebUI
@testable import ArcAgentCore

extension ArcWebUITestRoot {
    /// The "Create session" panel replaces the old "Context" tab: per-session
    /// context toggles (each with a literal-context disclosure), a stitched
    /// free-form custom-context list, and Create / Create-with-Defaults.
    @Suite("New session panel", .serialized)
    struct NewSessionPanelContractTests {

        private static func source(_ name: String) -> String {
            for base in ["Sources/ArcWebUI", "Sources/ArcAgentCore"] {
                if let s = try? String(contentsOfFile: "\(base)/\(name)", encoding: .utf8) {
                    return s
                }
            }
            return ""
        }

        @Test("the panel exists and the old Context tab is gone")
        func panelAndTabRemoval() {
            let views = Self.source("Views.swift")
            let app = Self.source("AppState.swift")
            #expect(views.contains("func newSessionPanelHTML()"))
            #expect(views.contains("Create with Defaults"))
            #expect(views.contains("Create Session"))
            #expect(!views.contains("func contextMain()"))
            #expect(!app.contains("case context = \"context\""))
        }

        @Test("segment toggles use the value channel and carry the segment in value")
        func segmentToggleUsesValueChannel() {
            let actions = Self.source("Actions.swift")
            let segWire = actions.slice(from: "wire(router, id: \"ns-seg\"", to: "wire(router, id: \"ns-custom\"")
            #expect(segWire.contains("string(\"value\")"))
            #expect(segWire.contains("ns-seg-"))
            #expect(segWire.contains("checked"))
        }

        @Test("one click boundary dispatches every panel button by targetId")
        func singleClickBoundaryDispatches() {
            let actions = Self.source("Actions.swift")
            let panelWire = actions.slice(from: "wire(router, id: \"new-session-panel\"", to: "private func wirePlugins")
            #expect(panelWire.contains("targetId"))
            for tid in ["ns-custom-add", "ns-create", "ns-defaults", "ns-cancel", "ns-custom-rm-"] {
                #expect(panelWire.contains(tid), "the click boundary must dispatch \(tid)")
            }
            // Buttons ride the card boundary (no per-button component boundary).
            let views = Self.source("Views.swift")
            #expect(!views.contains("data-component-id=\"ns-create\""))
            #expect(!views.contains("data-component-id=\"ns-custom-rm\""))
        }

        @Test("custom rows capture their index via the click channel")
        func customRowIndexViaClick() {
            let actions = Self.source("Actions.swift")
            #expect(actions.contains("setActiveCustomIndex"))
            let customWire = actions.slice(from: "wire(router, id: \"ns-custom\"", to: "wire(router, id: \"new-session-panel\"")
            #expect(customWire.contains("string(\"value\")"))
            #expect(customWire.contains("setNewSessionCustom"))
        }

        @Test("the recipe is seeded from resolved defaults and stitched via the core helper")
        func seedingAndStitching() {
            let act = Self.source("AppState+Actions.swift")
            #expect(act.contains("ResolvedContextRecipe.resolve("))
            #expect(act.contains("global: settings.contextDefaults"))
            #expect(act.contains("for seg in ContextSegment.allCases"))
            #expect(act.contains("ContextRecipe.stitchCustom(newSessionCustom)"))
        }

        @Test("per-segment previews produce their section header")
        func previewsHaveHeaders() {
            let act = Self.source("AppState+Actions.swift")
            #expect(act.contains("func contextSegmentPreview"))
            for header in ["## Memory (Your Persistent Notes)", "## User Profile", "## Environment", "## Workspace & Project Context", "## Personality", "Conversation started:"] {
                #expect(act.contains(header), "preview must surface \(header)")
            }
        }
    }
}

private extension String {
    /// The substring from `start` up to (not including) `end`.
    func slice(from start: String, to end: String) -> String {
        guard let a = range(of: start) else { return "" }
        let tail = self[a.upperBound...]
        if let b = tail.range(of: end) { return String(tail[..<b.lowerBound]) }
        return String(tail)
    }
}
