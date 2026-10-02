import Foundation
import Testing

@testable import ArcWebUI

/// `WorkspaceEntry` coding: `path` is the required anchor, `name` is optional
/// at the decode edge (derived from the folder) — and one hand-edited entry
/// must never wipe the whole workspaces list when settings decode.
@Suite("Workspace entry coding")
struct WorkspaceEntryCodingTests {

    @Test("an entry round-trips with both fields")
    func roundTrip() throws {
        let e = WorkspaceEntry(name: "no-webui", path: "/Users/x/workspace/no-webui")
        let back = try JSONDecoder().decode(WorkspaceEntry.self, from: JSONEncoder().encode(e))
        #expect(back == e)
    }

    @Test("a path-only entry derives its name")
    func pathOnlyDecodes() throws {
        let e = try JSONDecoder().decode(
            WorkspaceEntry.self, from: Data(#"{"path": "/Users/x/workspace/no-webui"}"#.utf8))
        #expect(e.name == "no-webui")
        #expect(e.path == "/Users/x/workspace/no-webui")
    }

    @Test("a name-only entry keeps the legacy per-name data folder")
    func nameOnlyDecodes() throws {
        let e = try JSONDecoder().decode(
            WorkspaceEntry.self, from: Data(#"{"name": "main"}"#.utf8))
        #expect(e.name == "main")
        #expect(e.path == WorkspaceEntry.defaultPath(for: "main"))
    }

    @Test("the legacy plain-string form still decodes")
    func legacyStringDecodes() throws {
        let e = try JSONDecoder().decode(
            WorkspaceEntry.self, from: Data(#""research""#.utf8))
        #expect(e.name == "research")
        #expect(e.path == WorkspaceEntry.defaultPath(for: "research"))
    }

    @Test("an entry with neither field is rejected, not silently invented")
    func emptyEntryRejected() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WorkspaceEntry.self, from: Data("{}".utf8))
        }
    }

    @Test("a settings file with a hand-edited path-only workspace keeps the whole list")
    func settingsDecodeKeepsList() throws {
        let json = #"{"workspaces": [{"name": "main", "path": "/Users/x/workspace"}, {"path": "/Users/x/workspace/no-webui"}]}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.workspaces.count == 2)
        #expect(s.workspaces[1].name == "no-webui")
        #expect(s.workspaces[1].path == "/Users/x/workspace/no-webui")
    }
}