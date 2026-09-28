import Foundation
import SwiftSlash

// MARK: - Goal loop engine (Hermes `features/goals.md` — Ralph loop)

/// The judge's verdict for a standing-goal continuation.
public struct GoalJudgeResult: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case done, `continue`, wait
    }
    public let kind: Kind
    public let reason: String
    /// Judge-provided wait hints (Hermes `wait_on_pid` / `wait_for_seconds`).
    public let waitOnPID: Int?
    public let waitForSeconds: Int?

    public init(kind: Kind, reason: String, waitOnPID: Int? = nil, waitForSeconds: Int? = nil) {
        self.kind = kind
        self.reason = reason
        self.waitOnPID = waitOnPID
        self.waitForSeconds = waitForSeconds
    }

    /// Parse the strict one-line JSON verdict (legacy `{"done": bool}` shape
    /// accepted too). Returns nil on malformed input.
    public static func parse(_ raw: String) -> GoalJudgeResult? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}") else { return nil }
        let slice = String(raw[start...end])
        guard let data = slice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let reason = obj["reason"] as? String ?? ""
        if let verdict = obj["verdict"] as? String {
            guard let kind = Kind(rawValue: verdict.lowercased()) else { return nil }
            return GoalJudgeResult(
                kind: kind, reason: reason,
                waitOnPID: obj["wait_on_pid"] as? Int,
                waitForSeconds: obj["wait_for_seconds"] as? Int
            )
        }
        // Legacy shape.
        if let done = obj["done"] as? Bool {
            return GoalJudgeResult(kind: done ? .done : .continue, reason: reason)
        }
        return nil
    }
}

/// What the goal loop says to do after a turn.
public enum GoalLoopOutcome: Sendable, Equatable {
    /// No goal active (or paused/done/blocked) — nothing to do.
    case idle
    /// A continuation turn should run next with this user-role text.
    case continueTurn(String)
    /// The loop stopped: done/paused. `message` is what to surface.
    case stopped(String)
}

/// The standing-goal engine: after every turn it runs gates, judges, and
/// decides whether to feed a continuation back into the same session.
public struct GoalLoop {

    /// Judge execution (injectable — production calls the agent's aux model).
    public typealias Judge = @Sendable (_ goal: GoalState, _ finalResponse: String) async -> GoalJudgeResult?

    /// Gate execution (injectable for tests; production shells out).
    public typealias GateRunner = @Sendable (_ command: String, _ timeoutSeconds: Int) async throws -> (exitCode: Int32, outputTail: String)

    public static func defaultGateRunner(workdir: String?) -> GateRunner {
        { command, timeout in
            var shell = Command(absolutePath: Path("/bin/bash"), arguments: ["-c", command])
            shell.inheritCurrentEnvironment()
            if let workdir { shell.workingDirectory = Path(workdir) }
            let outcome = try await SubprocessRunner.runBytes(shell, timeout: TimeInterval(timeout))
            let stdout = String(data: outcome.stdout, encoding: .utf8) ?? ""
            let stderr = String(data: outcome.stderr, encoding: .utf8) ?? ""
            let tail = String((stdout + "\n" + stderr).suffix(3000))
            return (outcome.exitCodeValue, tail)
        }
    }

    /// What to do after a completed turn (Hermes post-turn hook).
    public static func afterTurn(
        sessionID: String,
        store: any GoalStoring,
        finalResponse: String,
        judge: Judge,
        gateRunner: GateRunner,
        workspaceRoot: String?,
        processAlive: @Sendable (Int) async -> Bool = { pid in
            // `kill -0` probes liveness without signaling.
            var shell = Command(absolutePath: Path("/bin/bash"), arguments: ["-c", "kill -0 \(pid) 2>/dev/null"])
            shell.inheritCurrentEnvironment()
            let outcome = try? await SubprocessRunner.runBytes(shell, timeout: 3)
            return outcome?.exitCodeValue == 0
        }
    ) async throws -> GoalLoopOutcome {
        guard var goal = try await store.get(sessionID: sessionID) else { return .idle }
        guard goal.status == .active else { return .idle }

        // ── Wait barrier? Parked loops stay quiet until the barrier clears. ──
        if let barrier = goal.waitBarrier {
            let cleared: Bool
            if let pid = barrier.pid {
                cleared = !(await processAlive(pid))
            } else if let deadline = barrier.deadline {
                cleared = deadline <= Date()
            } else {
                cleared = false
            }
            if !cleared { return .idle }
            goal.waitBarrier = nil
            try await store.update(sessionID: sessionID) { $0.waitBarrier = nil }
        }

        // ── Quality gates run before the judge (deterministic evidence). ──
        if !goal.gates.isEmpty {
            // Replay-only-if-changed: a red gate with an unchanged workspace
            // fingerprint is not re-run (Hermes).
            for index in goal.gates.indices {
                var gate = goal.gates[index]
                if gate.passed == true { continue }
                let fingerprint = await workspaceFingerprint(workdir: workspaceRoot, runner: gateRunner)
                if fingerprint != nil, gate.lastFingerprint == fingerprint, gate.passed == false {
                    continue // Replay recorded failure.
                }
                do {
                    let (exit, tail) = try await gateRunner(gate.command, 300)
                    gate.passed = exit == 0
                    gate.lastOutput = tail
                    gate.lastFingerprint = fingerprint
                    goal.gates[index] = gate
                } catch {
                    gate.passed = false
                    gate.lastOutput = "gate errored: \(error)"
                    goal.gates[index] = gate
                }
            }
            try await store.update(sessionID: sessionID) { $0.gates = goal.gates }
            if let red = goal.gates.first(where: { $0.passed == false }) {
                let reason = "Quality gate failed: \(red.command)\n\(red.lastOutput ?? "")"
                return try await continueTurn(goal: try await store.get(sessionID: sessionID) ?? goal,
                                              reason: reason, store: store, sessionID: sessionID)
            }
        }

        // ── Judge (fail-open: any judge error = continue). ──
        let judged = await judge(goal, finalResponse)
        guard judged != nil else {
            return try await continueTurn(goal: goal, reason: "Judge unavailable — continuing.",
                                          store: store, sessionID: sessionID)
        }
        let result = judged!
        switch result.kind {
        case .done:
            try await store.update(sessionID: sessionID) {
                $0.status = .done
                $0.lastJudgeReason = result.reason
                $0.waitBarrier = nil
            }
            return .stopped("✓ Goal achieved: \(result.reason)")
        case .wait:
            try await store.update(sessionID: sessionID) {
                $0.waitBarrier = GoalWaitBarrier(
                    pid: result.waitOnPID,
                    deadline: result.waitForSeconds.map { Date().addingTimeInterval(TimeInterval($0)) },
                    reason: result.reason
                )
                $0.lastJudgeReason = result.reason
            }
            return .idle
        case .continue:
            return try await continueTurn(goal: goal, reason: result.reason, store: store, sessionID: sessionID)
        }
    }

    private static func continueTurn(
        goal: GoalState, reason: String, store: any GoalStoring, sessionID: String
    ) async throws -> GoalLoopOutcome {
        // Turn budget is the real backstop.
        let used = goal.turnsUsed + 1
        if used >= goal.maxTurns {
            try await store.update(sessionID: sessionID) {
                $0.status = .paused
                $0.turnsUsed = used
                $0.lastJudgeReason = reason
            }
            return .stopped("⏸ Goal paused — \(used)/\(goal.maxTurns) turns used. Use /goal resume to keep going, or /goal clear to stop.")
        }
        try await store.update(sessionID: sessionID) { $0.turnsUsed = used }
        return .continueTurn("[Continuing toward your standing goal]\n\(reason)")
    }

    /// Fingerprint HEAD + working-tree status; nil outside a git repo.
    private static func workspaceFingerprint(
        workdir: String?, runner: GateRunner
    ) async -> String? {
        guard let workdir else { return nil }
        do {
            let (headCode, headOut) = try await runner("git rev-parse HEAD 2>/dev/null", 10)
            guard headCode == 0 else { return nil }
            let (_, statusOut) = try await runner("git status --porcelain 2>/dev/null", 10)
            return "\(headOut.trimmingCharacters(in: .whitespacesAndNewlines))|\(statusOut.hashValue)"
        } catch {
            return nil
        }
    }

    /// Construct the judge prompt (conservative judge — done only on explicit
    /// confirmation or a clearly produced deliverable).
    public static func judgePrompt(goal: GoalState, finalResponse: String) -> String {
        var text = """
        You are the goal judge for an autonomous coding session. Reply with a single line of strict JSON only:
        {"verdict": "done" | "continue" | "wait", "reason": "<one sentence>"}
        Wait verdicts may add "wait_on_pid": <int> or "wait_for_seconds": <int>.

        You are deliberately conservative: mark done ONLY when the assistant's latest response explicitly
        confirms the goal is complete or the final deliverable is clearly produced, or the goal is
        unachievable/blocked. Otherwise continue.

        Goal: \(goal.text)
        """
        if let c = goal.contract {
            if let o = c.outcome { text += "\nRequired outcome: \(o)" }
            if let v = c.verification { text += "\nMust prove done with: \(v)" }
            if let cc = c.constraints { text += "\nMust not regress: \(cc)" }
            if let b = c.boundaries { text += "\nIn scope: \(b)" }
            if let s = c.stopWhen { text += "\nStop and ask when: \(s)" }
        }
        if !goal.subgoals.isEmpty {
            text += "\nAdditional criteria (all required):\n" + goal.subgoals.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        }
        text += "\n\nAssistant's latest response:\n\(String(finalResponse.suffix(4096)))\n\nVerdict:"
        return text
    }
}
