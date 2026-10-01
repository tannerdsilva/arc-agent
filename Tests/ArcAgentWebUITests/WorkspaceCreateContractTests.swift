import Foundation
import Testing

/// the workspace create surface, pinned against the sources (the house style
/// for wiring contracts that are not reachable as pure units):
/// - the composer's "Choose workspace path" opens ONE create form in chat
///   mode through the single open API;
/// - the form's fields keep the names the engine's submit payload uses
///   (`extractFormData` keys by the inputs' `name` attributes);
/// - the handler validates through `WorkspaceRules` instead of an inline gate.
///
/// regression context (2026-10-01): `ws-choose-path` used to set the create
/// flag and THEN switch views — `switchView` closes the create form, so the
/// form the flow promised never opened. The name gate rejected anything
/// outside `[a-z0-9_-]`, so a folder path typed into the Name field was
/// rejected "because of the symbol".
@Suite("Workspace create contract")
struct WorkspaceCreateContractTests {

    private static func source(_ name: String) -> String {
        (try? String(contentsOfFile: "Sources/ArcWebUI/\(name)", encoding: .utf8)) ?? ""
    }

    @Test("choose-path opens the form in chat mode through the single open API")
    func choosePathOpensChatForm() {
        let actions = Self.source("Actions.swift")
        #expect(actions.contains("openWorkspaceCreate(forChat: true)"),
                "the composer flow carries its chat intent into the create form")
        #expect(!actions.contains("setCreateWorkspace("),
                "the set-flag-then-switch-views pattern closed its own form; it must stay gone")
    }

    @Test("the create form keeps the submit payload field names")
    func formFieldContract() {
        let views = Self.source("Views.swift")
        #expect(views.contains("name=\"ws-path-input\""))
        #expect(views.contains("name=\"ws-name-input\""))
    }

    @Test("the handler validates through WorkspaceRules")
    func handlerUsesRules() {
        #expect(Self.source("Actions.swift").contains("WorkspaceRules.planEntry("),
                "path/name validation must stay in the shared rules, not inline in a wire")
    }

    @Test("switching views closes any open create form")
    func switchViewClosesForm() {
        #expect(Self.source("AppState+Actions.swift").contains("closeWorkspaceCreate()"))
    }
}