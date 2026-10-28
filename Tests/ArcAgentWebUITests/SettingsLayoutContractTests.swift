import Foundation
import Testing
@testable import ArcWebUI

extension ArcWebUITestRoot {
    /// Wiring contracts for the four Settings/Profile layout changes (2026-10):
    /// - Agent powers moved out of Settings onto the Profile page; AGENTS.md is
    ///   workspace-scoped and dropped from the profile-file lock list;
    /// - the run queue reorder flow (hidden #queue-order input + client DnD +
    ///   server reorder wire) instead of the old dead `queue-reorder` button;
    /// - targeted fragment refreshes everywhere: no whole-app (`includeApp`)
    ///   swaps remain, and the rail rides the targeted refresh;
    /// - model selection: per-config "Use" buttons replaced by the Main model
    ///   dropdown; aux forms pick from the model configurations.
    ///
    /// These are source-level pins (the house style for wiring contracts that are
    /// not reachable as pure units) — same shape as WorkspaceCreateContractTests.
    @Suite("Settings/Profile layout contract", .serialized)
    struct SettingsLayoutContractTests {

        private static func source(_ name: String) -> String {
            (try? String(contentsOfFile: "Sources/ArcWebUI/\(name)", encoding: .utf8)) ?? ""
        }

        private static func slice(_ s: String, from: String, to: String) -> String {
            guard let a = s.range(of: from), let b = s[a.upperBound...].range(of: to) else { return "" }
            return String(s[a.upperBound..<b.lowerBound])
        }

        // MARK: Agent powers → Profile page

        @Test("agent powers leave settings and land on the profile detail")
        func agentPowersPlacement() {
            let views = Self.source("Views.swift")
            let settings = Self.slice(views, from: "func settingsMain", to: "\n    func ")
            let profiles = Self.slice(views, from: "func profilesMain", to: "\n    func ")
            #expect(!settings.contains("agentPowersSection()"),
                    "agent powers must not render inside Settings anymore")
            #expect(profiles.contains("agentPowersSection()"),
                    "agent powers should render on the Profile detail page")
            #expect(profiles.contains("Agent powers"),
                    "the profile detail carries an Agent powers heading")
        }

        @Test("AGENTS.md is not a profile-locked file")
        func agentsIsNotProfileLocked() {
            let views = Self.source("Views.swift")
            #expect(!views.contains("(\"agents\", \"AGENTS.md\""),
                    "AGENTS.md is workspace-scoped and must not appear in the profile lock list")
            #expect(views.contains("(\"memory\", \"MEMORY.md\""))
            #expect(views.contains("(\"soul\", \"SOUL.md\""))
        }

        // MARK: Main model + aux pickers

        @Test("per-config Use buttons are gone; Main model dropdown exists")
        func mainModelPicker() {
            let views = Self.source("Views.swift")
            let actions = Self.source("Actions.swift")
            #expect(!views.contains("mc-use-"),
                    "choosing the main model moved to the Main model dropdown")
            #expect(views.contains("mainModelDropdown()"),
                    "a Main model card sits above the aux models")
            #expect(views.contains("func mainModelDropdown()"))
            #expect(actions.contains("@Wired(\"mainmc-toggle\""), "mainmc-toggle is @Wired")
            #expect(actions.contains("@Wired(\"mainmc\""), "mainmc is @Wired")
            #expect(actions.contains("useModelConfig(name)"),
                    "picking a row applies the configuration")
        }

        @Test("aux forms pick a model configuration (Main model default)")
        func auxConfigPicker() {
            let views = Self.source("Views.swift")
            let actions = Self.source("Actions.swift")
            #expect(views.contains("auxmc-main-"),
                    "the aux picker offers 'Main model' as its default row")
            #expect(views.contains("auxmc-toggle-"),
                    "the aux edit form has a styled configuration dropdown")
            #expect(actions.contains("@Wired(\"auxmc\""), "auxmc is @Wired")
            #expect(actions.contains("setAuxOverrideFromConfig(task: task, configName: staged)"),
                    "Save applies the chosen configuration (copied values)")
            #expect(actions.contains("clearAuxOverride(task: task)"),
                    "choosing Main model clears the override (falls back to main)")
            #expect(views.contains("summary = \"Main model\""),
                    "no override displays as Main model")
        }

        // MARK: Run queue reorder

        @Test("queue reorder flows through the hidden order input")
        func queueReorderContract() async {
            let queue = Self.source("Queue.swift")
            let overlay = (try? String(contentsOfFile: "Sources/ArcWebUI/Assets/overlay.js", encoding: .utf8)) ?? ""
            // the panel is a typed view now, so the hidden field is pinned in its
            // RENDERED bytes rather than in a source string.
            let panel = await AppState(renderFixture: .init()).queuePanelHTML().markup.html
            #expect(panel.contains("id=\"queue-order\""))
            #expect(panel.contains("data-component-id=\"queue-order\" data-event=\"change\""),
                    "the hidden input still owns its wire (change frames carry value only)")
            #expect(queue.contains("@Wired(\"queue-order\""),
                    "the hidden input owns its wire (change frames carry value only)")
            #expect(queue.contains("reorderQueue(order)"),
                    "the reorder wire persists via reorderQueue")
            #expect(!queue.contains("id=\"queue-reorder\""),
                    "the dead payload button must stay gone")
            #expect(overlay.contains(".queue-row"),
                    "the client drag handlers exist for queue rows")
            #expect(overlay.contains("queue-order") && overlay.contains("dispatchEvent(new Event('change'"),
                    "dropping pushes the new order through the hidden input")
            #expect(!queue.contains("'queue' data-event='change'") && !queue.contains("\"queue\" data-event=\"change\""),
                    "queue change controls must not dispatch by row identity on the shared queue boundary")
        }

        // MARK: Refresh behaviour

        @Test("the settings path re-renders the shell, and the shell carries what it needs")
        func targetedRefreshesOnly() async {
            // The settings path no longer assembles the `#app` shell by hand: the
            // font-size handler nudges, and the door's render is the whole shell.
            // The pin is on the two halves that made UX-22 work — the nudge, and
            // the attributes the live page needs the shell to carry.
            let actions = Self.source("Actions.swift")
            guard let start = actions.range(of: "func handleFontSizePick("),
                  let end = actions.range(of: "func ", range: start.upperBound..<actions.endIndex) else {
                Issue.record("handleFontSizePick not found in Actions.swift")
                return
            }
            let body = String(actions[start.lowerBound..<end.lowerBound])
            #expect(body.contains("return await self.changed()"),
                    "the font-size handler must still ask for a shell re-render so data-size lands live (UX-22)")
            let shell = await AppState(renderFixture: .init()).appShell().markup.html
            #expect(shell.contains("data-size="),
                    "the render the door derives must carry data-size, or a text-size change never lands (UX-22)")
            // the refresh must carry the rail so a view switch repaints the active
            // state in place; the shell is the only thing that emits it now.
            #expect(shell.contains("id=\"iconbar\""),
                    "the shell the door renders must carry the rail so view switches stay in place")
        }
    }
}
