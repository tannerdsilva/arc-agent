import Foundation
import Testing
@testable import ArcWebUI

/// Composer-upload staging: dropped/pasted chat files land under
/// `<arc home>/uploads/<sessionID>/` — never in a workspace — and the
/// per-chat folder is removable when the chat is deleted.
@Suite("Composer upload staging", .serialized)
struct ComposerUploadStagingTests {

    @Test func chatUploadDirNamesOneFolderPerSession() throws {
        let dir = try #require(AppState.chatUploadDir(sessionID: "7f3c9d2e-1234-abcd"))
        #expect(dir.lastPathComponent == "7f3c9d2e-1234-abcd")
        #expect(dir.deletingLastPathComponent().lastPathComponent == "uploads")
    }

    @Test func chatUploadDirRejectsPathTraversingIDs() {
        #expect(AppState.chatUploadDir(sessionID: "") == nil)
        #expect(AppState.chatUploadDir(sessionID: "  ") == nil)
        #expect(AppState.chatUploadDir(sessionID: "..") == nil)
        #expect(AppState.chatUploadDir(sessionID: ".") == nil)
        #expect(AppState.chatUploadDir(sessionID: "a/b") == nil)
        #expect(AppState.chatUploadDir(sessionID: "a\\b") == nil)
    }

    @Test func removeChatUploadsDeletesOnlyTheSessionFolder() throws {
        let root = AppState.chatUploadsRootURL()
        let mine = try #require(AppState.chatUploadDir(sessionID: "staging-test-session"))
        let other = try #require(AppState.chatUploadDir(sessionID: "staging-test-other"))
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: mine.appendingPathComponent("f.bin"))
        defer { try? FileManager.default.removeItem(at: other) }

        AppState.removeChatUploads(sessionID: "staging-test-session")
        #expect(!FileManager.default.fileExists(atPath: mine.path))
        #expect(FileManager.default.fileExists(atPath: other.path))

        // A missing folder is the normal no-uploads case: silent no-op.
        AppState.removeChatUploads(sessionID: "staging-test-session")
    }
}
