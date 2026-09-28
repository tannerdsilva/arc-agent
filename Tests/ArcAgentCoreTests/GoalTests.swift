import Testing
@testable import ArcAgentCore
import Foundation

/// Standing goals (Hermes `features/goals.md` Ralph loop).
@Suite("Goals", .serialized)
struct GoalTests {

    private func tempStore() throws -> GoalStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-goal-tests-\(UUID().uuidString).json")
        let store = try GoalStore()
        GoalStore.setStorageURL(url)
        return store
    }

    @Test("inline contract fields parse; incidental colon is not mangled")
    func contractParse() {
        let (headline, contract) = GoalState.parse(text: """
        Migrate auth to JWT
        verify: pytest tests/auth passes
        constraints: keep the /login response shape unchanged
        boundaries: only touch services/auth and its tests
        stop when: a DB schema migration is required
        """)
        #expect(headline == "Migrate auth to JWT")
        #expect(contract?.verification == "pytest tests/auth passes")
        #expect(contract?.constraints == "keep the /login response shape unchanged")
        #expect(contract?.boundaries == "only touch services/auth and its tests")
        #expect(contract?.stopWhen == "a DB schema migration is required")

        let (plain, noContract) = GoalState.parse(text: "Fix bug: the parser drops commas")
        #expect(plain == "Fix bug: the parser drops commas")
        #expect(noContract == nil)
    }

    @Test("judge verdict JSON parses (strict + legacy)")
    func verdictParse() {
        let done = GoalJudgeResult.parse(#"{"verdict": "done", "reason": "files created"}"#)
        #expect(done?.kind == .done)
        #expect(done?.reason == "files created")
        let cont = GoalJudgeResult.parse(#"{"verdict":"continue","reason":"2 of 4 remain"}"#)
        #expect(cont?.kind == .continue)
        let wait = GoalJudgeResult.parse(#"{"verdict": "wait", "reason": "watching CI", "wait_on_pid": 123}"#)
        #expect(wait?.kind == .wait)
        #expect(wait?.waitOnPID == 123)
        let legacy = GoalJudgeResult.parse(#"{"done": true, "reason": "ok"}"#)
        #expect(legacy?.kind == .done)
        #expect(GoalJudgeResult.parse("no json here") == nil)
    }

    @Test("store lifecycle and subgoals")
    func storeLifecycle() async throws {
        let store = try tempStore()
        var state = GoalState(text: "Write report", maxTurns: 3)
        try await store.set(sessionID: "s1", state: state)
        #expect(try await store.get(sessionID: "s1")?.text == "Write report")
        try await store.update(sessionID: "s1") { $0.addSubgoal("add appendix") }
        #expect(try await store.get(sessionID: "s1")?.subgoals == ["add appendix"])
        try await store.clear(sessionID: "s1")
        #expect(try await store.get(sessionID: "s1") == nil)
    }

    @Test("continue verdicts feed a continuation turn and advance budget")
    func continueFlow() async throws {
        let store = try tempStore()
        try await store.set(sessionID: "s1", state: GoalState(text: "Create 3 files", maxTurns: 20))
        let judge: GoalLoop.Judge = { _, _ in GoalJudgeResult(kind: .continue, reason: "2 of 3 remain") }
        let outcome = try await GoalLoop.afterTurn(
            sessionID: "s1", store: store, finalResponse: "made one",
            judge: judge,
            gateRunner: { _, _ in (0, "") },
            workspaceRoot: nil
        )
        guard case .continueTurn(let cont) = outcome else {
            Issue.record("expected continueTurn, got \(outcome)"); return
        }
        #expect(cont.contains("2 of 3 remain"))
        #expect(try await store.get(sessionID: "s1")?.turnsUsed == 1)
    }

    @Test("done stops the loop; budget pause messages the user")
    func doneAndBudget() async throws {
        let store = try tempStore()
        try await store.set(sessionID: "s1", state: GoalState(text: "Make 3 files", maxTurns: 2))
        let doneJudge: GoalLoop.Judge = { _, _ in GoalJudgeResult(kind: .done, reason: "all made") }
        let done = try await GoalLoop.afterTurn(
            sessionID: "s1", store: store, finalResponse: "all three made",
            judge: doneJudge, gateRunner: { _, _ in (0, "") }, workspaceRoot: nil
        )
        guard case .stopped(let msg) = done else {
            Issue.record("expected stopped, got \(done)"); return
        }
        #expect(msg.contains("Goal achieved"))
        #expect(try await store.get(sessionID: "s1")?.status == .done)

        try await store.set(sessionID: "s1", state: GoalState(text: "Iterate forever", maxTurns: 1))
        let contJudge: GoalLoop.Judge = { _, _ in GoalJudgeResult(kind: .continue, reason: "more") }
        let paused = try await GoalLoop.afterTurn(
            sessionID: "s1", store: store, finalResponse: "x",
            judge: contJudge, gateRunner: { _, _ in (0, "") }, workspaceRoot: nil
        )
        guard case .stopped(let pauseMsg) = paused else {
            Issue.record("expected pause, got \(paused)"); return
        }
        #expect(pauseMsg.contains("paused"))
        #expect(try await store.get(sessionID: "s1")?.status == .paused)
    }

    @Test("a red gate is deterministic: judge is skipped and reason carries output")
    func gateFail() async throws {
        let store = try tempStore()
        var state = GoalState(text: "Fix tests", maxTurns: 20)
        state.gates = [QualityGate(command: "pytest tests")]
        try await store.set(sessionID: "s1", state: state)
        var judged = false
        let judge: GoalLoop.Judge = { _, _ in judged = true; return GoalJudgeResult(kind: .done, reason: "never called") }
        let outcome = try await GoalLoop.afterTurn(
            sessionID: "s1", store: store, finalResponse: "fixed?",
            judge: judge,
            gateRunner: { _, _ in (1, "FAIL: 3 tests failed") },
            workspaceRoot: nil
        )
        guard case .continueTurn(let cont) = outcome else {
            Issue.record("expected continueTurn from red gate, got \(outcome)"); return
        }
        #expect(cont.contains("Quality gate failed"))
        #expect(judged == false)
    }

    @Test("judge error is fail-open (treated as continue)")
    func failOpen() async throws {
        let store = try tempStore()
        try await store.set(sessionID: "s1", state: GoalState(text: "Do the thing", maxTurns: 5))
        let judge: GoalLoop.Judge = { _, _ in nil }
        let outcome = try await GoalLoop.afterTurn(
            sessionID: "s1", store: store, finalResponse: "x",
            judge: judge, gateRunner: { _, _ in (0, "") }, workspaceRoot: nil
        )
        guard case .continueTurn = outcome else {
            Issue.record("expected fail-open continue, got \(outcome)"); return
        }
    }
}
