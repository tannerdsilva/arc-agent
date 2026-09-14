import Foundation
import Testing
@testable import ArcAgentCore

/// Approval choices (Hermes parity): always-allow allowlist, allow-session,
/// and yolo/skip-all — all bypass dangerous commands but critical commands
/// always require approval.
@Suite("Approval choices")
struct ApprovalChoicesTests {

    @Test("always-allowed command bypasses manual approval")
    func alwaysAllowedBypasses() async {
        let mgr = ApprovalManager(
            mode: .manual,
            alwaysAllowedCommands: ["rm -rf /tmp/cache"]
        )
        #expect(await mgr.needsApproval(command: "rm -rf /tmp/cache", sessionKey: "s1") == false)
        #expect(await mgr.needsApproval(command: "rm -rf /tmp/other", sessionKey: "s1") == true)
    }

    @Test("alwaysAllow persists through the sink and takes effect immediately")
    func alwaysAllowRecords() async {
        var persisted: [String] = []
        let mgr = ApprovalManager(mode: .manual)
        await mgr.setAlwaysAllowSink { cmd in persisted.append(cmd) }
        await mgr.alwaysAllow(command: "  sudo apt-get update  ")
        #expect(persisted == ["sudo apt-get update"])
        #expect(await mgr.needsApproval(command: "sudo apt-get update", sessionKey: "s2") == false)
    }

    @Test("allow-session bypasses dangerous but critical still prompts")
    func preApprovedSession() async {
        let mgr = ApprovalManager(mode: .manual)
        #expect(await mgr.needsApproval(command: "rm -rf /tmp/cache", sessionKey: "s3") == true)
        await mgr.preApproveSession("s3")
        #expect(await mgr.needsApproval(command: "rm -rf /tmp/cache", sessionKey: "s3") == false)
        #expect(await mgr.needsApproval(command: "rm -rf /", sessionKey: "s3") == true)
    }

    @Test("yolo bypasses dangerous but critical still prompts")
    func yoloKeepsCritical() async {
        let mgr = ApprovalManager(mode: .manual)
        #expect(await mgr.needsApproval(command: "rm -rf /tmp/cache", sessionKey: "s4", yolo: true) == false)
        #expect(await mgr.needsApproval(command: "rm -rf /", sessionKey: "s4", yolo: true) == true)
    }
}
