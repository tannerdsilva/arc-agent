import ArgumentParser
import ArcAgentCore
import AsyncHTTPClient
import Foundation

// MARK: - Goal CLI (reference `/goal`, `features/goals.md`)

/// `arc goal` — the Ralph loop: a standing objective that survives turns.
struct GoalCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "goal",
        abstract: "Manage a standing goal for a session (Ralph loop).",
        subcommands: [
            GoalSet.self, GoalDraft.self, GoalShow.self, GoalStatus.self,
            GoalPause.self, GoalResume.self, GoalClear.self,
            GoalWait.self, GoalUnwait.self, GoalGate.self
        ]
    )
}

func goalStoreForCLI() async throws -> any GoalStoring {
    if await TesseraAvailability.shared.isTesseraActive() {
        return TesseraGoalStore()
    }
    return GoalStore()
}

struct GoalSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "Set (or replace) the standing goal."
    )
    @Argument(help: "Session ID.")
    var session: String
    @Argument(help: "The goal text (may include contract field lines like 'verify: …').")
    var text: [String]

    func run() async throws {
        let joined = text.joined(separator: " ")
        let parsed = GoalState.parse(text: joined)
        let config = loadConfig()
        var state = GoalState(text: parsed.headline, maxTurns: config.goals.maxTurns)
        state.contract = parsed.contract
        let store = try await goalStoreForCLI()
        try await store.set(sessionID: session, state: state)
        try await store.save()
        print("⊙ Goal set (\(state.maxTurns)-turn budget): \(state.text)")
        if state.contract != nil {
            print("  Contract: outcome/verify/constraints/boundaries/stop-when parsed from input.")
        }
    }
}

struct GoalDraft: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "draft", abstract: "Draft a completion contract from a plain goal, then set it."
    )
    @Argument(help: "Session ID.")
    var session: String
    @Argument(help: "Plain-language objective.")
    var text: [String]

    func run() async throws {
        let objective = text.joined(separator: " ")
        let config = loadConfig()
        var state = GoalState(text: objective, maxTurns: config.goals.maxTurns)
        // Best-effort aux draft; drafting never blocks setting a goal.
        if let drafted = await draftContract(objective: objective, config: config) {
            state.contract = drafted
        }
        let store = try await goalStoreForCLI()
        try await store.set(sessionID: session, state: state)
        try await store.save()
        print("⊙ Goal set (\(state.maxTurns)-turn budget): \(state.text)")
        if let c = state.contract {
            print("  Contract:")
            if let o = c.outcome { print("    outcome: \(o)") }
            if let v = c.verification { print("    verification: \(v)") }
            if let cc = c.constraints { print("    constraints: \(cc)") }
            if let b = c.boundaries { print("    boundaries: \(b)") }
            if let s = c.stopWhen { print("    stop_when: \(s)") }
        } else {
            print("  (draft unavailable — plain goal set)")
        }
    }

    private func draftContract(objective: String, config: ArcConfig) async -> GoalContract? {
        let main = config.model
        let base = main.baseURL ?? "https://api.openai.com/v1"
        guard let url = URL(string: base) else { return nil }
        let env = ProcessInfo.processInfo.environment
        let apiKey = env["ARC_API_KEY"] ?? env["OPENAI_API_KEY"] ?? ""
        let client = OpenAICompatibleClient(
            baseURL: url, apiKey: apiKey,
            model: main.defaultModel, httpClient: HTTPClient(eventLoopGroupProvider: .singleton)
        )
        do {
            let prompt = """
            Expand this objective into a completion contract (JSON only):
            {"outcome": "...", "verification": "...", "constraints": "...", "boundaries": "...", "stop_when": "..."}
            All fields optional. Objective: \(objective)
            """
            let resp = try await client.complete(
                messages: [Message(role: .user, content: prompt)],
                tools: nil, reasoningEffort: nil
            )
            let content = resp.content ?? ""
            guard let start = content.firstIndex(of: "{"),
                  let end = content.lastIndex(of: "}") else { return nil }
            let data = String(content[start...end]).data(using: .utf8) ?? Data()
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return GoalContract(
                outcome: obj["outcome"] as? String,
                verification: obj["verification"] as? String,
                constraints: obj["constraints"] as? String,
                boundaries: obj["boundaries"] as? String,
                stopWhen: obj["stop_when"] as? String
            )
        } catch {
            return nil
        }
    }
}

struct GoalShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Print the active goal's completion contract.")
    @Argument var session: String
    func run() async throws {
        let store = try await goalStoreForCLI()
        guard let goal = try await store.get(sessionID: session) else {
            print("No goal set for session \(session)."); return
        }
        print("Goal: \(goal.text)")
        if let c = goal.contract {
            if let o = c.outcome { print("outcome: \(o)") }
            if let v = c.verification { print("verification: \(v)") }
            if let cc = c.constraints { print("constraints: \(cc)") }
            if let b = c.boundaries { print("boundaries: \(b)") }
            if let s = c.stopWhen { print("stop_when: \(s)") }
        } else {
            print("contract: (none)")
        }
        if !goal.subgoals.isEmpty {
            print("subgoals:")
            for (i, sg) in goal.subgoals.enumerated() { print("  \(i + 1). \(sg)") }
        }
        if !goal.gates.isEmpty {
            print("gates:")
            for (i, g) in goal.gates.enumerated() {
                print("  \(i + 1). \(g.command)  [\(g.passed == true ? "pass" : g.passed == false ? "FAIL" : "pending")]")
            }
        }
    }
}

struct GoalStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show the current goal, status, and turns used.")
    @Argument(help: "Session ID (omit for all).")
    var session: String?
    func run() async throws {
        let store = try await goalStoreForCLI()
        if let session {
            guard let goal = try await store.get(sessionID: session) else {
                print("No goal set for session \(session)."); return
            }
            print("Session: \(session)")
            print("  Goal:   \(goal.text)")
            print("  Status: \(goal.status.rawValue)")
            print("  Turns:  \(goal.turnsUsed)/\(goal.maxTurns)")
            print("  Paused: \(goal.status == .paused ? "yes" : "no")")
            if let b = goal.waitBarrier {
                print("  Parked: pid=\(b.pid.map(String.init(describing:)) ?? "-") deadline=\(b.deadline?.description ?? "-") \(b.reason ?? "")")
            }
            if let r = goal.lastJudgeReason { print("  Last:   \(r)") }
        } else {
            let all = try await store.all()
            if all.isEmpty { print("No goals set."); return }
            for key in all.keys.sorted() {
                let g = all[key]!
                print("\(key)  [\(g.status.rawValue)]  \(g.turnsUsed)/\(g.maxTurns)  \(g.text.prefix(50))")
            }
        }
    }
}

struct GoalPause: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pause", abstract: "Stop the auto-continuation loop without clearing the goal.")
    @Argument var session: String
    func run() async throws {
        let store = try await goalStoreForCLI()
        try await store.update(sessionID: session) { $0.status = .paused }
        try await store.save()
        print("⏸ Goal paused for \(session). Use `arc goal resume` to keep going.")
    }
}

struct GoalResume: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "resume", abstract: "Resume the loop (resets the turn counter).")
    @Argument var session: String
    func run() async throws {
        let store = try await goalStoreForCLI()
        try await store.update(sessionID: session) {
            $0.status = .active
            $0.turnsUsed = 0
            $0.waitBarrier = nil
        }
        try await store.save()
        print("⊙ Goal resumed for \(session) (counter reset).")
    }
}

struct GoalClear: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clear", abstract: "Drop the goal entirely.")
    @Argument var session: String
    func run() async throws {
        let store = try await goalStoreForCLI()
        try await store.clear(sessionID: session)
        try await store.save()
        print("⊙ Goal cleared for \(session).")
    }
}

struct GoalWait: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "wait", abstract: "Park the loop until a PID exits.")
    @Argument var session: String
    @Argument var pid: Int
    @Argument(help: "Optional reason.") var reason: String?
    func run() async throws {
        let store = try await goalStoreForCLI()
        try await store.update(sessionID: session) {
            $0.waitBarrier = GoalWaitBarrier(pid: pid, reason: reason)
        }
        try await store.save()
        print("⏳ Goal parked for \(session) until PID \(pid) exits.")
    }
}

struct GoalUnwait: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "unwait", abstract: "Drop the wait barrier and resume immediately.")
    @Argument var session: String
    func run() async throws {
        let store = try await goalStoreForCLI()
        try await store.update(sessionID: session) { $0.waitBarrier = nil }
        try await store.save()
        print("⊙ Wait barrier cleared for \(session).")
    }
}

struct GoalGate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gate", abstract: "Manage deterministic quality gates.",
        subcommands: [GoalGateAdd.self, GoalGateList.self, GoalGateRemove.self, GoalGateClear.self]
    )
}

struct GoalGateAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add a shell command that must pass before done.")
    @Argument var session: String
    @Argument var command: [String]
    func run() async throws {
        let store = try await goalStoreForCLI()
        guard try await store.get(sessionID: session) != nil else {
            print("No goal set for session \(session)."); return
        }
        try await store.update(sessionID: session) { $0.gates.append(QualityGate(command: command.joined(separator: " "))) }
        try await store.save()
        print("➕ Gate added for \(session): \(command.joined(separator: " "))")
    }
}

struct GoalGateList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List the goal's gates.")
    @Argument var session: String
    func run() async throws {
        let store = try await goalStoreForCLI()
        guard let goal = try await store.get(sessionID: session) else {
            print("No goal set for session \(session)."); return
        }
        if goal.gates.isEmpty { print("No gates for \(session)."); return }
        for (i, g) in goal.gates.enumerated() {
            print("\(i + 1). \(g.command)  [\(g.passed == true ? "pass" : g.passed == false ? "FAIL" : "pending")]")
        }
    }
}

struct GoalGateRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove the Nth gate (1-based).")
    @Argument var session: String
    @Argument var index: Int
    func run() async throws {
        let store = try await goalStoreForCLI()
        try await store.update(sessionID: session) { state in
            guard state.gates.indices.contains(index - 1) else { return }
            state.gates.remove(at: index - 1)
        }
        try await store.save()
        print("➖ Gate \(index) removed for \(session).")
    }
}

struct GoalGateClear: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clear", abstract: "Remove all gates.")
    @Argument var session: String
    func run() async throws {
        let store = try await goalStoreForCLI()
        try await store.update(sessionID: session) { $0.gates = [] }
        try await store.save()
        print("🧹 All gates removed for \(session).")
    }
}

// MARK: - Subgoals (reference `/subgoal`)

struct SubgoalCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "subgoal",
        abstract: "Append or manage additional acceptance criteria for the active goal.",
        subcommands: [SubgoalAdd.self, SubgoalShow.self, SubgoalRemove.self, SubgoalClear.self]
    )
}

struct SubgoalAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Append a criterion.")
    @Argument var session: String
    @Argument var text: [String]
    func run() async throws {
        let store = try await goalStoreForCLI()
        guard try await store.get(sessionID: session) != nil else {
            print("No active goal for session \(session). Use `arc goal set` first."); return
        }
        try await store.update(sessionID: session) { $0.addSubgoal(text.joined(separator: " ")) }
        try await store.save()
        print("⊕ Subgoal added for \(session).")
    }
}

struct SubgoalShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show the numbered subgoal list.")
    @Argument var session: String
    func run() async throws {
        let store = try await goalStoreForCLI()
        guard let goal = try await store.get(sessionID: session) else {
            print("No goal set for session \(session)."); return
        }
        if goal.subgoals.isEmpty { print("No subgoals for \(session)."); return }
        for (i, sg) in goal.subgoals.enumerated() { print("\(i + 1). \(sg)") }
    }
}

struct SubgoalRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove the Nth subgoal (1-based).")
    @Argument var session: String
    @Argument var index: Int
    func run() async throws {
        let store = try await goalStoreForCLI()
        try await store.update(sessionID: session) { state in
            guard state.subgoals.indices.contains(index - 1) else { return }
            state.subgoals.remove(at: index - 1)
        }
        try await store.save()
        print("➖ Subgoal \(index) removed for \(session).")
    }
}

struct SubgoalClear: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clear", abstract: "Drop every subgoal but keep the goal.")
    @Argument var session: String
    func run() async throws {
        let store = try await goalStoreForCLI()
        try await store.update(sessionID: session) { $0.subgoals = [] }
        try await store.save()
        print("🧹 Subgoals cleared for \(session).")
    }
}
