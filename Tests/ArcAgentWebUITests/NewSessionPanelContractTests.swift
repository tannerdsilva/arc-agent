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

        @Test("add-custom is dispatched before the generic ns-custom- prefix branch")
        func addCustomPrioritizedOverPrefix() {
            let actions = Self.source("Actions.swift")
            let panelWire = actions.slice(from: "wire(router, id: \"new-session-panel\"", to: "private func wirePlugins")
            guard let add = panelWire.range(of: "== \"ns-custom-add\""),
                  let prefix = panelWire.range(of: "hasPrefix(\"ns-custom-\")") else {
                #expect(Bool(false), "click boundary must contain both the add dispatch and the prefix branch")
                return
            }
            // "ns-custom-add" shares the `ns-custom-` prefix with the numeric
            // textarea ids, so the prefix branch must come AFTER the exact
            // add match — otherwise `Int("add")` is nil and the row never appends.
            #expect(add.lowerBound < prefix.lowerBound,
                    "ns-custom-add must be dispatched before the generic ns-custom- prefix branch")
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

        @Test("the custom list starts empty; rows appear only on add and remove back to none")
        func customListStartsEmpty() {
            let act = Self.source("AppState+Actions.swift")
            // Seeded straight from resolved defaults (no forced blank row).
            #expect(act.contains("newSessionCustom = recipe.customItems"))
            // The old behaviour that pre-seeded one empty row is gone.
            #expect(!act.contains("? [CustomContextItem"))
            // Remove always removes (the user can get back to zero rows), and
            // the old "clear the text instead of removing the last row" branch is gone.
            #expect(act.contains("newSessionCustom.remove(at: idx)"))
            // The old "clear the text instead of removing the last row" branch is gone.
            #expect(!act.contains("if newSessionCustom.count > 1"))
            #expect(!act.contains("newSessionCustom[idx] = CustomContextItem(text: \"\")"))
        }

        @Test("per-segment previews produce their section header")
        func previewsHaveHeaders() {
            let act = Self.source("AppState+Actions.swift")
            #expect(act.contains("func contextSegmentPreview"))
            for header in ["## Memory (Your Persistent Notes)", "## User Profile", "## Environment", "## Workspace & Project Context", "## Personality", "Conversation started:"] {
                #expect(act.contains(header), "preview must surface \(header)")
            }
        }

        @Test("each custom row carries a low/medium/high weight select")
        func customRowsCarryWeightSelect() {
            let views = Self.source("Views.swift")
            #expect(views.contains("data-component-id=\"nsw\""))
            #expect(views.contains("class=\"session-custom-weight\""))
            #expect(views.contains("data-event=\"change\""))
            for w in ["low", "medium", "high"] {
                #expect(views.contains("value=\"\(w)\""), "weight select must offer \(w)")
            }
        }

        @Test("the weight select is wired to set the row's weight on change")
        func weightSelectChangeWired() {
            let actions = Self.source("Actions.swift")
            let weightWire = actions.slice(from: "wire(router, id: \"nsw\"", to: "wire(router, id: \"new-session-panel\"")
            #expect(weightWire.contains("events: [\"change\"]"))
            #expect(weightWire.contains("CustomContextWeight(rawValue:"))
            #expect(weightWire.contains("setNewSessionCustomWeight"))
            // It must round-trip through activeCustomIndex (change frames carry
            // no targetId), the same contract the text-area change uses.
            #expect(weightWire.contains("activeCustomIndex"))
        }

        @Test("clicking a weight select records the active row (nsw- branch)")
        func weightSelectTracksActiveRow() {
            let actions = Self.source("Actions.swift")
            let panelWire = actions.slice(from: "wire(router, id: \"new-session-panel\"", to: "private func wirePlugins")
            #expect(panelWire.contains("hasPrefix(\"nsw-\")"))
            #expect(panelWire.contains("setActiveCustomIndex"))
        }

        @Test("the custom-context preview mirrors the weight-tiered prompt framing")
        func customPreviewMirrorsTiers() {
            let views = Self.source("Views.swift")
            #expect(views.contains("## Custom Context (High)"))
            #expect(views.contains("You MUST follow these instructions in every response:"))
            #expect(views.contains("## Custom Context (Medium)"))
            #expect(views.contains("Follow these instructions for this session:"))
            #expect(views.contains("## Custom Context (Low)"))
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
