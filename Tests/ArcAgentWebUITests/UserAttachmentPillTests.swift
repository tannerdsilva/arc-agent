import ArcAgentCore
import Foundation
import Testing
import WebUI
@testable import ArcWebUI

/// Sent user messages show staged attachments as pills above the bubble
/// text (reference webui parity) and never leak the raw `[attachment: …]`
/// marker lines the model sees.
@Suite("User message attachment pills", .serialized)
struct UserAttachmentPillTests {

    private func makeAppState() async throws -> AppState {
        try await AppState()
    }

    private func html(for message: Message) async throws -> String {
        let app = try await makeAppState()
        return await app.messageHTML(message).markup.html
    }

    @Test func markersRenderAsPillsAndAreStrippedFromTheText() async throws {
        let html = try await html(for: Message(
            role: .user,
            content: "[attachment: /Users/x/.arc/uploads/s1/nowebui-file-fix.md]\n\nReplay with exactly confirm",
            createdAt: Date()))

        #expect(html.contains("msg-attachments"))
        #expect(html.contains("nowebui-file-fix.md"))
        #expect(!html.contains("[attachment:"))
        #expect(html.contains("Replay with exactly confirm"))
    }

    @Test func imageDescriptionsStayHiddenButThePillShows() async throws {
        let html = try await html(for: Message(
            role: .user,
            content: "[attachment: /tmp/chart.png]\n[Image description: a rising line chart]\n\nWhat trend is this?",
            createdAt: Date()))

        #expect(html.contains("chart.png"))
        #expect(!html.contains("[Image description:"))
        #expect(html.contains("What trend is this?"))
    }

    @Test func plainMessagesStayUnchanged() async throws {
        let html = try await html(for: Message(
            role: .user, content: "Just words", createdAt: Date()))
        #expect(!html.contains("msg-attachments"))
        #expect(html.contains("Just words"))
    }
}
