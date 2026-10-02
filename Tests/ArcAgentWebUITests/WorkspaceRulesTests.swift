import Foundation
import Testing

@testable import ArcWebUI

/// the workspace preset contract: `path` is required and adheres to Unix path
/// standards; `name` is an optional label, derived from the folder when blank.
/// the matrix is pure — the filesystem seam is injected — plus one integration
/// test against a real temp folder.
///
/// regression context (2026-10-01): the create flow demanded a name matching
/// `[a-z0-9_-]`, so a folder path typed into the Name field (the composer's
/// "Choose workspace path" flow invites exactly that) was rejected "because of
/// the symbol" and no path-only preset could be created at all.
@Suite("Workspace rules")
struct WorkspaceRulesTests {

    private static let anyDirectory: (String) -> Bool = { _ in true }
    private static let noDirectory: (String) -> Bool = { _ in false }
    private static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    // MARK: path

    @Test("paths are standardized: repeated separators, '.', '..' and trailing slashes collapse")
    func pathStandardization() throws {
        let e = try WorkspaceRules.planEntry(
            name: "no-webui",
            path: "//Users//x/./workspace/../workspace/no-webui/",
            existing: [], isDirectory: Self.anyDirectory)
        #expect(e.path == "/Users/x/workspace/no-webui")
        #expect(e.name == "no-webui")
    }

    @Test("'~' and '~/…' expand to the home folder")
    func tildeExpansion() throws {
        let derived = try WorkspaceRules.planEntry(
            name: "", path: "~/workspace/no-webui",
            existing: [], isDirectory: Self.anyDirectory)
        #expect(derived.path == Self.home + "/workspace/no-webui")
        #expect(derived.name == "no-webui", "a blank name derives from the folder")

        let homeItself = try WorkspaceRules.planEntry(
            name: "home", path: "~",
            existing: [], isDirectory: Self.anyDirectory)
        #expect(homeItself.path == Self.home)
    }

    @Test("a relative path is rejected as not absolute")
    func relativeRejected() {
        #expect(throws: WorkspaceRuleError.pathNotAbsolute("workspace/no-webui")) {
            try WorkspaceRules.planEntry(
                name: "x", path: "workspace/no-webui",
                existing: [], isDirectory: Self.anyDirectory)
        }
    }

    @Test("an empty path is rejected")
    func emptyPathRejected() {
        #expect(throws: WorkspaceRuleError.pathRequired) {
            try WorkspaceRules.planEntry(
                name: "x", path: "   ",
                existing: [], isDirectory: Self.anyDirectory)
        }
    }

    @Test("control characters are rejected in paths and names")
    func controlCharactersRejected() {
        #expect(throws: WorkspaceRuleError.pathContainsControlCharacters) {
            try WorkspaceRules.planEntry(
                name: "x", path: "/tmp/a\u{01}b",
                existing: [], isDirectory: Self.anyDirectory)
        }
        #expect(throws: WorkspaceRuleError.nameInvalid("control characters")) {
            try WorkspaceRules.planEntry(
                name: "a\u{7F}b", path: "/tmp/x",
                existing: [], isDirectory: Self.anyDirectory)
        }
    }

    @Test("the path must point at an existing folder")
    func pathMustBeAFolder() {
        #expect(throws: WorkspaceRuleError.pathNotAFolder("/tmp/gone")) {
            try WorkspaceRules.planEntry(
                name: "x", path: "/tmp/gone",
                existing: [], isDirectory: Self.noDirectory)
        }
    }

    @Test("a folder another workspace already uses is rejected, naming the holder")
    func duplicatePathRejected() {
        let existing = [WorkspaceEntry(name: "main", path: "/Users/x/workspace")]
        for variant in ["/Users/x/workspace", "/Users/x/workspace/", "/Users/x/./workspace"] {
            #expect(throws: WorkspaceRuleError.pathAlreadyUsed(path: "/Users/x/workspace", name: "main")) {
                try WorkspaceRules.planEntry(
                    name: "other", path: variant,
                    existing: existing, isDirectory: Self.anyDirectory)
            }
        }
    }

    // MARK: name

    @Test("a blank name derives from the folder; an explicit name keeps its case and symbols")
    func nameResolution() throws {
        let derived = try WorkspaceRules.planEntry(
            name: "  ", path: "/Users/x/My.Project + v2",
            existing: [], isDirectory: Self.anyDirectory)
        #expect(derived.name == "My.Project + v2")

        let explicit = try WorkspaceRules.planEntry(
            name: "No-WebUI 2.0", path: "/Users/x/y",
            existing: [], isDirectory: Self.anyDirectory)
        #expect(explicit.name == "No-WebUI 2.0", "labels are not lowercased or symbol-stripped")
    }

    @Test("the filesystem root derives the fallback name")
    func rootDerivesFallback() throws {
        let e = try WorkspaceRules.planEntry(
            name: "", path: "/",
            existing: [], isDirectory: Self.anyDirectory)
        #expect(e.name == "workspace")
    }

    @Test("a path-like name is rejected with guidance to the Folder path field")
    func pathLikeNameRejected() {
        let err = WorkspaceRuleError.nameContainsSlash
        #expect(throws: err) {
            try WorkspaceRules.planEntry(
                name: "~/workspace/no-webui", path: "/tmp/x",
                existing: [], isDirectory: Self.anyDirectory)
        }
        #expect(err.description.contains("Folder path"), "the message redirects to the path field")
    }

    @Test("an explicit name collision is an error; a derived collision auto-numbers")
    func collisions() throws {
        let existing = [
            WorkspaceEntry(name: "main", path: "/a"),
            WorkspaceEntry(name: "no-webui", path: "/b"),
        ]
        #expect(throws: WorkspaceRuleError.nameExists("Main")) {
            try WorkspaceRules.planEntry(
                name: "Main", path: "/c",
                existing: existing, isDirectory: Self.anyDirectory)
        }
        let second = try WorkspaceRules.planEntry(
            name: "", path: "/x/no-webui",
            existing: existing, isDirectory: Self.anyDirectory)
        #expect(second.name == "no-webui-2")
        let third = try WorkspaceRules.planEntry(
            name: "", path: "/y/no-webui",
            existing: existing + [WorkspaceEntry(name: "no-webui-2", path: "/z")],
            isDirectory: Self.anyDirectory)
        #expect(third.name == "no-webui-3")
    }

    @Test("dot names are reserved")
    func dotNamesRejected() {
        for name in [".", ".."] {
            #expect(throws: WorkspaceRuleError.nameInvalid("'.' and '..' are reserved")) {
                try WorkspaceRules.planEntry(
                    name: name, path: "/tmp/x",
                    existing: [], isDirectory: Self.anyDirectory)
            }
        }
    }

    // MARK: real filesystem

    @Test("a real folder on disk is accepted; a real file is not")
    func realFilesystem() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("arc-ws-rules-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: file)

        let entry = try WorkspaceRules.planEntry(name: "", path: dir.path, existing: [])
        #expect(entry.name == dir.lastPathComponent)
        #expect(entry.path == (dir.path as NSString).standardizingPath)

        #expect(throws: WorkspaceRuleError.pathNotAFolder(file.path)) {
            try WorkspaceRules.planEntry(name: "x", path: file.path, existing: [])
        }
    }
}