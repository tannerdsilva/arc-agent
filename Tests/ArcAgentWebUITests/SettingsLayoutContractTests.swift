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
        func mainModelPicker() async {
            let views = Self.source("Views.swift")
            let actions = Self.source("Actions.swift")
            #expect(!views.contains("mc-use-"),
                    "choosing the main model moved to the Main model dropdown")
            #expect(views.contains("mainModelDropdown()"),
                    "a Main model card sits above the aux models")
            #expect(views.contains("func mainModelDropdown()"))
            #expect(!actions.contains("@WireGroup(\"settings\")"),
                    "the settings boot group is retired; registration moved to the render pass")
            var fixture = AppState.RenderFixture()
            fixture.settings.modelConfigs = [
                ModelConfigPreset(name: "fast", model: "gpt-5-mini", provider: "openai", baseURL: ""),
            ]
            fixture.settings.activeConfig = "fast"
            let html = await AppState(renderFixture: fixture).mainModelDropdown().markup.html
            #expect(html.contains("data-component-id=\"mainmc-toggle\" data-event=\"click\""),
                    "the trigger carries its render-time routing pair")
            #expect(html.contains("data-component-id=\"mainmc\" data-event=\"click\""),
                    "the popover boundary carries its render-time routing pair")
            #expect(views.contains("useModelConfig(name)"),
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
            #expect(views.contains("controlAttributes(id: \"auxmc\"") ||
                    views.contains(".control(id: \"auxmc\""),
                    "the aux picker boundary registers at render time")
            #expect(!actions.contains("@WireGroup(\"settings\")"),
                    "the settings boot group is retired; registration moved to the render pass")
            #expect(views.contains("setAuxOverrideFromConfig(task: task, configName: staged)"),
                    "Save applies the chosen configuration (copied values)")
            #expect(views.contains("clearAuxOverride(task: task)"),
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
            // 2.6.0: the engine's data-reorder handler owns the drag. It writes
            // the moved children's ids into #queue-order and dispatches `change`,
            // so the container names the input and the rows carry entry ids.
            #expect(panel.contains("data-reorder=\"queue-order\""),
                    "the run-queue container must hand the reorder to the engine")
            #expect(panel.contains("data-reorder=\"queue-order\"") && queue.contains(".id(e.id)"),
                    "each row's id is the queue entry id the order input consumes")
            #expect(!overlay.contains(".queue-row"),
                    "the overlay must not keep a second drag owner for queue rows")
            #expect(!queue.contains("'queue' data-event='change'") && !queue.contains("\"queue\" data-event=\"change\""),
                    "queue change controls must not dispatch by row identity on the shared queue boundary")
        }

        // MARK: Refresh behaviour

        @Test("the settings path re-renders the shell, and the shell carries what it needs")
        func targetedRefreshesOnly() async {
            // No producer assembles the `#app` shell by hand any more: the door's
            // render is the whole shell. Scan every UI source file (the offender
            // once hid outside Actions) for a producer that names the root.
            let dir = "Sources/ArcWebUI"
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir))?
                .filter { $0.hasSuffix(".swift") } ?? []
            var offenders: [String] = []
            for f in files {
                let src = (try? String(contentsOfFile: "\(dir)/\(f)", encoding: .utf8)) ?? ""
                if src.contains("fragment(\"app\"") || src.contains("FragmentUpdate(id: \"app\"") {
                    offenders.append(f)
                }
            }
            #expect(offenders.isEmpty,
                    "whole-app swaps remain in: \(offenders.joined(separator: ", "))")
            // The settings path still re-renders the shell without a reload: the
            // font-size handler signals, and the door's render is the whole
            // shell — so the pin is on the two halves that made UX-22 work.
            // The handler registers at render time now, so it lives in Views.
            let views = Self.source("Views.swift")
            guard let start = views.range(of: ".control(id: \"font-size-pick\")"),
                  let end = views.range(of: "func ", range: start.upperBound..<views.endIndex) else {
                Issue.record("font-size-pick control not found in Views.swift")
                return
            }
            let body = String(views[start.lowerBound..<end.lowerBound])
            #expect(body.contains("await self.signalStructure()"),
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
