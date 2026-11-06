import Foundation
import Testing
@testable import ArcWebUI

/// The X on a staged-upload chip deletes the staged file (and empties the
/// per-chat staging folder); attachments outside the staging root are
/// never touched. Pending attachments are per-chat across switches.
@Suite("Attachment chip discard", .serialized)
struct AttachmentChipDiscardTests {

    private func makeAppState() async throws -> AppState {
        try await AppState()
    }

    @Test func removingStagedChipDeletesTheFile() async throws {
        let app = try await makeAppState()
        let dir = try #require(AppState.chatUploadDir(sessionID: "chip-discard-test"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("dropped.bin")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: dir) }

        await app.addAttachment(file.path)
        await app.removeAttachment(0)

        #expect(!FileManager.default.fileExists(atPath: file.path))
        // the emptied staging folder is tidied away too
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func removingNonStagedChipNeverTouchesTheFile() async throws {
        let app = try await makeAppState()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("chip-keep-\(UUID().uuidString).txt")
        try Data("keep".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        await app.addAttachment(tmp.path)
        await app.removeAttachment(0)

        #expect(FileManager.default.fileExists(atPath: tmp.path))
    }

    @Test func pendingAttachmentsSurviveChatSwitch() async throws {
        let app = try await makeAppState()
        let dir = try #require(AppState.chatUploadDir(sessionID: "switch-test"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("keep.bin")
        try Data("x".utf8).write(to: file)
        defer {
            try? FileManager.default.removeItem(at: dir)
        }

        await app.setActiveSession("switch-test")
        await app.addAttachment(file.path)
        #expect(await app.attachments.count == 1)

        // leave for another chat, then come back: the chip must still be there
        await app.setActiveSession("switch-test-other")
        #expect(await app.attachments.isEmpty)
        await app.setActiveSession("switch-test")
        let visible = await app.attachments
        #expect(visible.count == 1)
        #expect(visible[0] == file.path)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
