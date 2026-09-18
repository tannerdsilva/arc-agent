import Testing
import Foundation
@testable import ArcAgentCore

// MARK: - Agent limits config (max_turns + guardrails.toolLoopCap)

@Suite("Agent limits config")
struct AgentLimitsConfigTests {

    private func decode(_ json: String) throws -> ArcConfig {
        try JSONDecoder().decode(ArcConfig.self, from: Data(json.utf8))
    }

    @Test("agent.max_turns takes precedence (Hermes precedence)")
    func agentMaxTurnsWins() throws {
        let cfg = try decode(#"{"agent": {"max_turns": 120, "maxIterations": 10}}"#)
        #expect(cfg.effectiveMaxTurns() == 120)
    }

    @Test("legacy root max_turns used when agent.max_turns absent")
    func rootMaxTurnsFallback() throws {
        let cfg = try decode(#"{"max_turns": 50, "agent": {"maxIterations": 10}}"#)
        #expect(cfg.effectiveMaxTurns() == 50)
    }

    @Test("agent.maxIterations used when no max_turns set")
    func maxIterationsFallback() throws {
        let cfg = try decode(#"{"agent": {"maxIterations": 7}}"#)
        #expect(cfg.effectiveMaxTurns() == 7)
    }

    @Test("zero or negative max_turns means unlimited")
    func negativeMeansUnlimited() throws {
        let cfg = try decode(#"{"agent": {"max_turns": -1}}"#)
        #expect(cfg.effectiveMaxTurns() == Int.max)
        let zero = try decode(#"{"max_turns": 0}"#)
        #expect(zero.effectiveMaxTurns() == Int.max)
    }

    @Test("bare config falls back to agent.maxIterations (arc-native default 25)")
    func defaultIsArcNative() throws {
        let cfg = try decode(#"{}"#)
        #expect(cfg.effectiveMaxTurns() == 25)
    }

    @Test("effectiveToolLoopCap honors guardrails.toolLoopCap")
    func toolLoopCap() throws {
        let cfg = try decode(#"{"guardrails": {"toolLoopCap": 3}}"#)
        #expect(cfg.effectiveToolLoopCap() == 3)
    }

    @Test("effectiveToolLoopCap negative or zero is unlimited")
    func toolLoopCapUnlimited() throws {
        let cfg = try decode(#"{"guardrails": {"toolLoopCap": -1}}"#)
        #expect(cfg.effectiveToolLoopCap() == Int.max)
        let zero = try decode(#"{"guardrails": {"toolLoopCap": 0}}"#)
        #expect(zero.effectiveToolLoopCap() == Int.max)
    }

    @Test("effectiveToolLoopCap default is 25")
    func toolLoopCapDefault() throws {
        let cfg = try decode(#"{}"#)
        #expect(cfg.effectiveToolLoopCap() == 25)
    }

    @Test("missing keys decode safely and old configs round-trip")
    func missingKeysSafe() throws {
        let cfg = try decode(#"{"agent": {"maxIterations": 25, "persistSessions": true}}"#)
        #expect(cfg.agent.max_turns == nil)
        #expect(cfg.guardrails.toolLoopCap == nil)
        #expect(cfg.effectiveMaxTurns() == 25)
    }
}

// MARK: - ToolGuardrails loopCap override

@Suite("ToolGuardrails loop cap override")
struct ToolGuardrailsLoopCapTests {

    @Test("limits.loopCap overrides the default 25")
    func overrideHonored() async {
        let g = ToolGuardrails(limits: .init(loopCap: 3))
        for i in 0..<3 {
            if case .synthetic = await g.decide(toolName: "terminal", args: ["cmd": "true \(i)"]) {
                Issue.record("calls 1-3 should be allowed")
                return
            }
        }
        let fourth = await g.decide(toolName: "terminal", args: ["cmd": "true 3"])
        #expect(fourth == .synthetic("Tool call limit reached for terminal after 4 calls (cap 3). Do not repeat this same call again; try a different approach or ask the user."))
    }

    @Test("unlimited (0) never hits the per-tool synthetic cap")
    func unlimitedCallsAllowed() async {
        let g = ToolGuardrails(limits: .init(loopCap: 0))
        var synthetics = 0
        for i in 0..<120 {
            if case .synthetic = await g.decide(toolName: "terminal", args: ["cmd": "echo \(i)"]) {
                synthetics += 1
            }
        }
        #expect(synthetics == 0)
    }

    @Test("unlimited still catches identical-call loops (floor of 10)")
    func repeatFloorStillCatches() async {
        let g = ToolGuardrails(limits: .init(loopCap: 0))
        var syntheticAt: Int? = nil
        for i in 1...14 {
            let d = await g.decide(toolName: "terminal", args: ["cmd": "same"])
            if case .synthetic = d, syntheticAt == nil { syntheticAt = i }
        }
        #expect(syntheticAt == 11)
    }

    @Test("negative loopCap behaves like unlimited")
    func negativeUnlimited() async {
        let g = ToolGuardrails(limits: .init(loopCap: -1))
        var synthetics = 0
        for i in 0..<60 {
            if case .synthetic = await g.decide(toolName: "read_file", args: ["path": "/tmp/x\(i)"]) {
                synthetics += 1
            }
        }
        #expect(synthetics == 0)
    }
}
