import Testing
@testable import ArcWebUI
import Foundation

/// Regression tests for per-chat workspace pinning: a chat's workspace is
/// frozen when the chat is created (or first used) and must never silently
/// follow the global default afterwards. Switching the workspace tabs only
/// affects *new* chats; an explicit in-chat selection is the only thing that
/// moves an existing chat. Pins live in the persisted settings, so they
/// survive restarts.
@Suite("Session workspace pinning")
struct SessionWorkspacePinningTests {

    @Test("pin freezes the current default for the session")
    func pinAssignsCurrentDefault() {
        var s = AppSettings()
        s.activeWorkspace = "projects"

        let pinned = s.pinWorkspace(for: "chat-1")

        #expect(pinned == "projects")
        #expect(s.sessionWorkspaces["chat-1"] == "projects")
    }

    @Test("switching the global default does not move a pinned chat")
    func defaultSwitchDoesNotMovePinnedChat() {
        var s = AppSettings()
        s.activeWorkspace = "main"
        s.pinWorkspace(for: "chat-1")

        s.activeWorkspace = "other"

        #expect(s.sessionWorkspaces["chat-1"] == "main",
                "pinned chats must not follow the global default")
    }

    @Test("pin is idempotent — an explicit in-chat selection wins")
    func pinKeepsExplicitSelection() {
        var s = AppSettings()
        s.sessionWorkspaces["chat-1"] = "projects"

        let pinned = s.pinWorkspace(for: "chat-1")

        #expect(pinned == "projects")
        #expect(s.sessionWorkspaces["chat-1"] == "projects")
    }

    @Test("pins survive a settings round-trip (restart)")
    func pinsSurviveCodableRoundTrip() throws {
        var s = AppSettings()
        s.activeWorkspace = "main"
        s.pinWorkspace(for: "chat-1")

        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        #expect(decoded.sessionWorkspaces["chat-1"] == "main")
    }

    @Test("pinning a session with an empty stored name re-pins to the default")
    func pinReplacesEmptyEntry() {
        var s = AppSettings()
        s.activeWorkspace = "main"
        s.sessionWorkspaces["chat-1"] = ""

        let pinned = s.pinWorkspace(for: "chat-1")

        #expect(pinned == "main")
        #expect(s.sessionWorkspaces["chat-1"] == "main")
    }
}
