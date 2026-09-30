import Foundation

// MARK: - Standing goals (reference `features/goals.md`, Ralph loop)

/// Optional completion contract (reference `/goal draft` five-field shape).
public struct GoalContract: Codable, Sendable, Equatable {
    public var outcome: String?
    public var verification: String?
    public var constraints: String?
    public var boundaries: String?
    public var stopWhen: String?

    public init(outcome: String? = nil, verification: String? = nil,
                constraints: String? = nil, boundaries: String? = nil,
                stopWhen: String? = nil) {
        self.outcome = outcome
        self.verification = verification
        self.constraints = constraints
        self.boundaries = boundaries
        self.stopWhen = stopWhen
    }
}

/// A quality gate: a deterministic shell command that must exit 0 before the
/// goal may be judged done (reference `/goal gate add <command>`).
public struct QualityGate: Codable, Sendable, Equatable {
    public var command: String
    /// Tracks whether the last run passed (nil = not run yet).
    public var passed: Bool?
    /// Last output tail (fed to the continuation prompt on failure).
    public var lastOutput: String?
    /// Git fingerprint (HEAD + working-tree status) when the gate was last run.
    public var lastFingerprint: String?

    public init(command: String, passed: Bool? = nil,
                lastOutput: String? = nil, lastFingerprint: String? = nil) {
        self.command = command
        self.passed = passed
        self.lastOutput = lastOutput
        self.lastFingerprint = lastFingerprint
    }
}

/// A wait barrier parks the loop (reference `/goal wait`, judge `wait` verdicts).
public struct GoalWaitBarrier: Codable, Sendable, Equatable {
    public var pid: Int?
    public var deadline: Date?
    public var reason: String?

    public init(pid: Int? = nil, deadline: Date? = nil, reason: String? = nil) {
        self.pid = pid
        self.deadline = deadline
        self.reason = reason
    }
}

/// Per-session standing goal state (reference `SessionDB.state_meta` keyed
/// `goal:<session_id>`).
public struct GoalState: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case active, paused, done
    }

    public var text: String
    public var contract: GoalContract?
    public var subgoals: [String] = []
    public var gates: [QualityGate] = []
    public var status: Status = .active
    public var turnsUsed: Int = 0
    public var maxTurns: Int = 20
    public var waitBarrier: GoalWaitBarrier?
    public var lastJudgeReason: String?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public init(text: String, maxTurns: Int = 20) {
        self.text = text
        self.maxTurns = maxTurns
    }

    /// reference `/subgoal`: append one numbered criterion.
    public mutating func addSubgoal(_ criterion: String) {
        subgoals.append(criterion)
    }

    /// Parse reference' inline contract fields (known prefixes only; a bare
    /// incidental colon never mangles the headline).
    public static func parse(text: String) -> (headline: String, contract: GoalContract?) {
        var headline = ""
        var contract = GoalContract()
        let lines = text.components(separatedBy: .newlines)
        var headlineLines: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            func take(_ prefix: String, into key: WritableKeyPath<GoalContract, String?>) {
                guard lower.hasPrefix(prefix) else { return }
                let value = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { return }
                contract[keyPath: key] = value
            }
            take("verify:", into: \.verification)
            take("verified by:", into: \.verification)
            take("constraints:", into: \.constraints)
            take("preserve:", into: \.constraints)
            take("boundaries:", into: \.boundaries)
            take("scope:", into: \.boundaries)
            take("stop when:", into: \.stopWhen)
            take("outcome:", into: \.outcome)
            if !trimmed.isEmpty && anyFieldLine(lower) == false {
                headlineLines.append(trimmed)
            }
        }
        headline = headlineLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if headline.isEmpty { headline = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let has = [contract.outcome, contract.verification, contract.constraints,
                   contract.boundaries, contract.stopWhen].contains { $0?.isEmpty == false }
        return (headline, has ? contract : nil)
    }

    private static func anyFieldLine(_ lower: String) -> Bool {
        ["verify:", "verified by:", "constraints:", "preserve:", "boundaries:",
         "scope:", "stop when:", "outcome:"].contains { lower.hasPrefix($0) }
    }
}

/// Durable per-session goal store (`~/.arc/goals.json`).
///
/// The shared abstraction for everything that runs the Ralph loop: the file
/// implementation (default, local) and ``TesseraGoalStore`` (signed NOSTR
/// events when Tessera storage is active). Both backends keep the same
/// per-session ``GoalState`` semantics.
public protocol GoalStoring: Sendable {
    /// Set or replace the session's goal (subgoals/gates reset — reference).
    func set(sessionID: String, state: GoalState) async throws
    func get(sessionID: String) async throws -> GoalState?
    func update(sessionID: String, _ mutate: @Sendable (inout GoalState) -> Void) async throws
    func clear(sessionID: String) async throws
    func all() async throws -> [String: GoalState]
    /// Flush any buffered writes (no-op for write-through backends).
    func save() async throws
}

public actor GoalStore: GoalStoring {

    private nonisolated(unsafe) static var storageURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".arc/goals.json")

    public static func setStorageURL(_ url: URL) {
        storageURL = url
    }

    private var goals: [String: GoalState] = [:]

    public init() {}

    public init(loadFrom url: URL? = nil) throws {
        let target = url ?? Self.storageURL
        if let data = try? Data(contentsOf: target),
           let decoded = try? JSONDecoder().decode([String: GoalState].self, from: data) {
            goals = decoded
        }
    }

    /// Set or replace the session's goal (subgoals/gates reset — reference).
    public func set(sessionID: String, state: GoalState) async throws {
        var s = state
        s.createdAt = Date()
        s.updatedAt = Date()
        goals[sessionID] = s
    }

    public func get(sessionID: String) async throws -> GoalState? {
        goals[sessionID]
    }

    public func update(sessionID: String, _ mutate: @Sendable (inout GoalState) -> Void) async throws {
        guard var g = goals[sessionID] else { return }
        mutate(&g)
        g.updatedAt = Date()
        goals[sessionID] = g
    }

    public func clear(sessionID: String) async throws {
        goals[sessionID] = nil
    }

    public func all() async throws -> [String: GoalState] {
        goals
    }

    public func save() async throws {
        let target = Self.storageURL
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(goals)
        try data.write(to: target, options: .atomic)
    }
}
