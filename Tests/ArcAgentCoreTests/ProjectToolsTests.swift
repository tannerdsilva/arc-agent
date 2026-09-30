import Testing
@testable import ArcAgentCore
import Foundation

/// Single-threaded recorder shared with a `@Sendable` closure.
final class SeenRecorder: @unchecked Sendable {
    var items: [String?] = []
}

/// Project store + tools (reference `tools/project_tools.py` parity).
@Suite("Project tools", .serialized)
struct ProjectToolsTests {

    private func withTempStore(_ body: (URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-project-tests-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("projects.json")
        ProjectStore.setStorageURL(url)
        let hook = ProjectStore.workspaceHook
        ProjectStore.workspaceHook = nil
        defer {
            ProjectStore.setStorageURL(FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".arc/projects.json"))
            ProjectStore.workspaceHook = hook
            try? FileManager.default.removeItem(at: dir)
        }
        try await body(url)
    }

    @Test("create makes the project active and persists it")
    func createActivates() async throws {
        try await withTempStore { _ in
            let store = ProjectStore()
            let p = try await store.create(name: "Aurora Demo", path: "/tmp/aurora")
            #expect(p.name == "Aurora Demo")
            #expect(p.slug == "aurora-demo")
            #expect(p.primaryPath == "/tmp/aurora")
            let active = try await store.active()
            #expect(active?.id == p.id)
            #expect(try await store.list().count == 1)
        }
    }

    @Test("project_list tool reports active flag")
    func listTool() async throws {
        try await withTempStore { _ in
            let store = ProjectStore()
            try await store.create(name: "Alpha", path: nil)
            try await store.create(name: "Beta", path: nil)
            let out = try await ProjectListTool.entry.handler([:])
            #expect(out.contains("\"name\":\"Alpha\""))
            #expect(out.contains("\"name\":\"Beta\""))
            // reference format uses snake_case keys
            #expect(out.contains("\"active_id\""))
            #expect(out.contains("\"primary_path\""))
        }
    }

    @Test("project_create tool returns success JSON + switches")
    func createTool() async throws {
        try await withTempStore { _ in
            let out = try await ProjectCreateTool.entry.handler(["name": "Gamma", "path": "/repo/gamma"])
            #expect(out.contains("\"success\":true"))
            #expect(out.contains("\"name\":\"Gamma\""))
            let active = try await ProjectStore().active()
            #expect(active?.name == "Gamma")
        }
    }

    @Test("project_switch resolves by slug/name case-insensitively")
    func switchTool() async throws {
        try await withTempStore { _ in
            let store = ProjectStore()
            try await store.create(name: "First Project", path: nil)
            try await store.create(name: "Second Project", path: "/s/second")
            let out = try await ProjectSwitchTool.entry.handler(["project": "second-project"])
            #expect(out.contains("\"success\":true"))
            #expect(out.contains("\"name\":\"Second Project\""))
            #expect(try await store.active()?.slug == "second-project")

            let missing = try await ProjectSwitchTool.entry.handler(["project": "nope"])
            #expect(missing.contains("\"success\":false"))
        }
    }

    @Test("empty name errors as the reference contract")
    func createInvalid() async throws {
        try await withTempStore { _ in
            let out = try await ProjectCreateTool.entry.handler(["name": "  "])
            #expect(out.contains("\"success\":false"))
            #expect(out.contains("name is required"))
        }
    }

    @Test("workspace hook fires on create and switch")
    func hookFires() async throws {
        try await withTempStore { _ in
            let store = ProjectStore()
            let seen = SeenRecorder()
            ProjectStore.workspaceHook = { path in seen.items.append(path) }
            try await store.create(name: "Hooked", path: "/hooked/path")
            #expect(seen.items.last ?? nil == "/hooked/path")
            try await store.create(name: "Other", path: nil)
            #expect(seen.items.last ?? nil == nil)
        }
    }
}
