import Foundation
import Testing
@testable import ArcWebUI
import ArcAgentCore

extension ArcWebUITestRoot {

    /// Headless approval policy (CONVERGE A6): the pure decision function the
    /// scheduler runs when nobody can answer a card. Pin it here — the worst
    /// failure mode of this plan is approvals going silent, so every branch of
    /// the policy has a test and nothing about it depends on a turn, a socket,
    /// or an LLM.
    @Suite("Headless approval policy", .serialized)
    struct HeadlessApprovalPolicyTests {

        /// A safe command proceeds when not denied; a manager denial blocks it.
        @Test("safe command proceeds unless the manager denied it")
        func safeCommandProceeds() {
            #expect(HeadlessApprovalPolicy.verdict(dangerLevel: .safe) == .proceed)
            #expect(HeadlessApprovalPolicy.verdict(dangerLevel: .safe, approval: .denied) == .block(Self.blocked))
            #expect(HeadlessApprovalPolicy.verdict(dangerLevel: .safe, approval: .approved) == .proceed)
        }

        /// A suspicious command proceeds unless the manager denied it.
        @Test("suspicious command proceeds unless denied")
        func suspiciousCommand() {
            #expect(HeadlessApprovalPolicy.verdict(dangerLevel: .suspicious) == .proceed)
            #expect(HeadlessApprovalPolicy.verdict(dangerLevel: .suspicious, approval: .approved) == .proceed)
            #expect(HeadlessApprovalPolicy.verdict(dangerLevel: .suspicious, approval: .denied) == .block(Self.blocked))
        }

        /// A dangerous command proceeds only when not denied; critical never proceeds.
        @Test("dangerous and critical commands")
        func dangerousAndCritical() {
            #expect(HeadlessApprovalPolicy.verdict(dangerLevel: .dangerous, approval: .approved) == .proceed)
            #expect(HeadlessApprovalPolicy.verdict(dangerLevel: .dangerous, approval: .denied) == .block(Self.blocked))
            #expect(HeadlessApprovalPolicy.verdict(dangerLevel: .critical, approval: .approved) == .block(Self.blocked))
            #expect(HeadlessApprovalPolicy.verdict(dangerLevel: .critical, approval: .denied) == .block(Self.blocked))
            #expect(HeadlessApprovalPolicy.verdict(dangerLevel: .critical) == .block(Self.blocked))
        }

        /// The refusal text is byte-for-byte the constant the inline headless
        /// branch returned before this policy was extracted.
        @Test("block message matches the inline branch text")
        func blockMessageMatchesConstant() {
            #expect(HeadlessApprovalPolicy.blockedCommandMessage ==
                "Error: command blocked by approval policy (classified critical; scheduled jobs cannot run destructive commands).")
        }

        /// The `ApprovalPresenter` decision mirrors the verdict: deny on
        /// critical, approve otherwise.
        @Test("decision mirrors the policy")
        func decisionMirrorsPolicy() {
            #expect(HeadlessApprovalPolicy.decision(dangerLevel: .critical) == .deny)
            #expect(HeadlessApprovalPolicy.decision(dangerLevel: .dangerous) == .approve)
            #expect(HeadlessApprovalPolicy.decision(dangerLevel: .safe) == .approve)
        }

        // the shared refusal text (duplicated here as the pin, not the source
        // of truth — the source of truth is `HeadlessApprovalPolicy`).
        private static let blocked =
            "Error: command blocked by approval policy (classified critical; scheduled jobs cannot run destructive commands)."
    }
}
