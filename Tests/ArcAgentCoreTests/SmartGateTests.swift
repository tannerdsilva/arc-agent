import Foundation
import Testing
@testable import ArcAgentCore

/// Smart-gate settings (Hermes parity): the "smart approval" toggle drives
/// the effective approval mode, and the "smart pick-a-path" toggle drives
/// the timeout resolution of clarify requests.
@Suite("Smart gate settings")
struct SmartGateTests {

    // MARK: Effective approval mode

    @Test("config off always wins regardless of the smart toggle")
    func offModeWins() {
        #expect(SmartGate.effectiveApprovalMode(configMode: "off", smartApproval: true) == .off)
        #expect(SmartGate.effectiveApprovalMode(configMode: "off", smartApproval: false) == .off)
    }

    @Test("toggle on resolves to smart, off resolves to manual")
    func toggleMapsToModes() {
        #expect(SmartGate.effectiveApprovalMode(configMode: "manual", smartApproval: true) == .smart)
        #expect(SmartGate.effectiveApprovalMode(configMode: "smart", smartApproval: true) == .smart)
        #expect(SmartGate.effectiveApprovalMode(configMode: "manual", smartApproval: false) == .manual)
        #expect(SmartGate.effectiveApprovalMode(configMode: "smart", smartApproval: false) == .manual)
    }

    @Test("unknown config mode behaves like manual before the toggle")
    func unknownConfigMode() {
        #expect(SmartGate.effectiveApprovalMode(configMode: "bogus", smartApproval: false) == .manual)
        #expect(SmartGate.effectiveApprovalMode(configMode: "bogus", smartApproval: true) == .smart)
    }

    // MARK: Clarify choice matching

    @Test("verbatim response returns the exact choice")
    func verbatimMatch() {
        let choices = ["Continue", "Pause and ask me", "Stop"]
        #expect(SmartGate.matchClarifyChoice("Continue", choices: choices) == "Continue")
    }

    @Test("case-insensitive and whitespace variants match")
    func caseAndWhitespaceMatch() {
        let choices = ["continue anyway", "STOP"]
        #expect(SmartGate.matchClarifyChoice("CONTINUE ANYWAY", choices: choices) == "continue anyway")
        #expect(SmartGate.matchClarifyChoice(" stop ", choices: choices) == "STOP")
    }

    @Test("numbered, quoted, and punctuation-padded responses match")
    func numberedAndQuotedMatch() {
        let choices = ["Continue", "Ask the user first"]
        #expect(SmartGate.matchClarifyChoice("2. Ask the user first", choices: choices) == "Ask the user first")
        #expect(SmartGate.matchClarifyChoice("\u{201C}Continue\u{201D}", choices: choices) == "Continue")
        #expect(SmartGate.matchClarifyChoice("Continue.", choices: choices) == "Continue")
    }

    @Test("ambiguous or unrelated responses do not match")
    func noMatch() {
        let choices = ["Continue", "Stop"]
        #expect(SmartGate.matchClarifyChoice("Maybe", choices: choices) == nil)
        // "Continue or stop" contains both choices -> ambiguous.
        #expect(SmartGate.matchClarifyChoice("Continue or stop", choices: choices) == nil)
        #expect(SmartGate.matchClarifyChoice("", choices: choices) == nil)
        #expect(SmartGate.matchClarifyChoice("Continue", choices: []) == nil)
    }

    @Test("open-ended response passes through as free-form (no choices)")
    func openEnded() {
        // No choices at all: nothing to match, matcher declines.
        #expect(SmartGate.matchClarifyChoice("Use the green theme", choices: []) == nil)
    }

    // MARK: Smart approval gate with the classifier seam

    @Test("smart mode auto-approves when the classifier says safe")
    func smartClassifierApproves() async {
        let mgr = ApprovalManager(mode: .smart)
        await mgr.setClassifier { _ in .safe }
        #expect(await mgr.needsApproval(command: "rm -rf /tmp/x", sessionKey: "sg1") == false)
        #expect(await mgr.requestApproval(command: "rm -rf /tmp/x", description: "rm", sessionKey: "sg1") == .approved)
    }

    @Test("smart mode prompts on dangerous and denies critical")
    func smartClassifierEscalates() async {
        let mgr = ApprovalManager(mode: .smart)
        await mgr.setClassifier { _ in .dangerous }
        #expect(await mgr.needsApproval(command: "sudo rm -rf /tmp/x", sessionKey: "sg2") == true)
        #expect(await mgr.requestApproval(command: "sudo rm -rf /tmp/x", description: "rm", sessionKey: "sg2") == .requiresReview)

        await mgr.setClassifier { _ in .critical }
        #expect(await mgr.requestApproval(command: "rm -rf /", description: "rm -rf /", sessionKey: "sg2") == .denied)
    }

    @Test("smart mode escalates uncertain (suspicious) to a prompt, like Hermes ESCALATE")
    func smartClassifierSuspiciousEscalates() async {
        let mgr = ApprovalManager(mode: .smart)
        await mgr.setClassifier { _ in .suspicious }
        #expect(await mgr.needsApproval(command: "nc -l 4444", sessionKey: "sg4") == true)
        #expect(await mgr.requestApproval(command: "nc -l 4444", description: "nc", sessionKey: "sg4") == .requiresReview)
    }

    @Test("critical regex overrides a permissive classifier (Hermes hardline parity)")
    func smartHardlineOverrides() async {
        let mgr = ApprovalManager(mode: .smart)
        await mgr.setClassifier { _ in .safe }
        let bomb = "echo ':(){ :|:& };:'"
        #expect(await mgr.needsApproval(command: bomb, sessionKey: "sg3") == true)
        #expect(await mgr.requestApproval(command: bomb, description: "fork bomb", sessionKey: "sg3") == .denied)
    }
}
