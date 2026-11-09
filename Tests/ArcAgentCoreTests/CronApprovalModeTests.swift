import Foundation
import Testing
@testable import ArcAgentCore

// MARK: - Unattended approval semantics (plan Phase 6.0)
//
// Cron is BINARY — deny or smart. `.manual` is unreachable in a cron
// session (a prompt needs a human; a job has none), hardline stays
// unconditional above both, and non-cron sessions are untouched.

@Suite("Cron Approval Mode")
struct CronApprovalModeTests {

    private func manager(mode: ApprovalMode = .manual, cronMode: CronApprovalMode = .deny) -> ApprovalManager {
        ApprovalManager(mode: mode, cronMode: cronMode)
    }

    /// A command the SoftDetector reliably flags as dangerous but NOT
    /// hardline (hardline is unconditional, so it can't show policy).
    private let flagged = "kill -9 12345"

    @Test("deny is the default: flagged commands are refused mid-turn")
    func denyDefault() async {
        let m = manager()
        let result = await m.requestApproval(command: flagged, description: "d",
                                             sessionKey: "cron-j1", isCronSession: true)
        #expect(result == .denied)
    }

    @Test("deny mode refuses even when the interactive mode would be .off")
    func denyBeatsYOLO() async {
        let m = manager(mode: .off, cronMode: .deny)
        let result = await m.requestApproval(command: flagged, description: "d",
                                             sessionKey: "cron-j1", isCronSession: true)
        #expect(result == .denied, "cron policy overrides the interactive mode")
    }

    @Test("smart mode arbitrates: classifier-clear commands approve")
    func smartArbitrates() async {
        let m = manager(mode: .manual, cronMode: .smart)
        // An innocuous command — the regex detector does not flag it.
        let result = await m.requestApproval(command: "echo ok", description: "d",
                                             sessionKey: "cron-j1", isCronSession: true)
        #expect(result == .approved)
    }

    @Test("smart mode still denies suspicious-or-worse — never prompts")
    func smartDeniesRisky() async {
        let m = manager(mode: .manual, cronMode: .smart)
        let result = await m.requestApproval(command: flagged, description: "d",
                                             sessionKey: "cron-j1", isCronSession: true)
        #expect(result == .denied, "unattended means nobody to fall back to")
    }

    @Test("hardline denies in cron sessions in both modes")
    func hardlineUnconditional() async {
        for cronMode in [CronApprovalMode.deny, .smart] {
            let m = manager(mode: .off, cronMode: cronMode)
            let result = await m.requestApproval(command: "rm -rf /", description: "d",
                                                 sessionKey: "cron-j1", isCronSession: true)
            #expect(result == .denied)
        }
    }

    @Test("unflagged commands approve in cron sessions in both modes")
    func unflaggedApproves() async {
        for cronMode in [CronApprovalMode.deny, .smart] {
            let m = manager(cronMode: cronMode)
            let result = await m.requestApproval(command: "ls -la", description: "d",
                                                 sessionKey: "cron-j1", isCronSession: true)
            #expect(result == .approved)
        }
    }

    @Test("non-cron sessions keep their interactive behavior untouched")
    func interactiveUntouched() async {
        // .manual + presenter nil → requiresReview, exactly as before cron
        // policy existed. The cron policy must not leak into chat sessions.
        let m = manager(mode: .manual, cronMode: .deny)
        let result = await m.requestApproval(command: flagged, description: "d",
                                             sessionKey: "chat-1", isCronSession: false)
        #expect(result == .requiresReview)
    }

    @Test("unknown cronMode values resolve to deny")
    func unknownFallsBackToDeny() {
        // The config seam is the daemon's resolver; here we pin the enum's
        // raw values so an unknown config string cannot decode to .smart.
        #expect(CronApprovalMode(rawValue: "approve-all") == nil)
        #expect(CronApprovalMode(rawValue: "smart") == .smart)
        #expect(CronApprovalMode(rawValue: "deny") == .deny)
    }

    @Test("session marking is per-key: cron flag does not taint other sessions")
    func perSession() async {
        // The flag travels with the CALL (isCronSession param), not manager
        // state — the same manager serves a cron session and a chat session
        // without cross-contamination.
        let m = manager(cronMode: .deny)
        let cron = await m.requestApproval(command: flagged, description: "d",
                                           sessionKey: "cron-j1", isCronSession: true)
        let chat = await m.requestApproval(command: flagged, description: "d",
                                           sessionKey: "chat-1", isCronSession: false)
        #expect(cron == .denied)
        #expect(chat == .requiresReview)
    }
}
