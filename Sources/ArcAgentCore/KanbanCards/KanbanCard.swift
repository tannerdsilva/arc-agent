import Foundation

// ==========================================================================
// KanbanCards — the Hermes-parity card model.
//
// Concept-for-concept port of the reference agent's kanban (tasks,
// task_runs, task_links, task_comments, task_events, task_attachments)
// onto Swift value types persisted through the CardStore protocol
// (tessera when configured, files otherwise).
//
// Parity notes:
//   * Statuses match exactly: triage / todo / ready / running / blocked /
//     done / archived.
//   * Block kinds match exactly: dependency / needs_input / capability /
//     transient. `dependency` blocks route to `todo` (auto-resume via
//     recomputeReady), never into the human `blocked` bucket.
//   * Run outcomes match exactly: completed / blocked / crashed /
//     timed_out / spawn_failed / gave_up / reclaimed.
//   * The run is the unit of accounting: claim state, heartbeat,
//     structured summary, and the terminal outcome live on the run,
//     not the task. `CardTask.currentRunID` points at the live one.
//   * The one deliberate divergence: no notify-subs table (the reference
//     agent's gateway notifier is chat-platform-specific; arc's eventual
//     equivalent rides send_message).
// ==========================================================================

/// Lifecycle status of a `CardTask`. Matches the reference agent exactly.
public enum CardStatus: String, Sendable, Codable, CaseIterable {
    case triage
    case todo
    case ready
    case running
    case blocked
    case done
    case archived
}

/// Why a task is blocked. Matches the reference `VALID_BLOCK_KINDS`.
public enum CardBlockKind: String, Sendable, Codable, CaseIterable {
    /// Waiting on a parent task — routes to `todo`, auto-resumes.
    case dependency
    /// Needs a human decision or answer.
    case needs_input
    /// A hard wall: no access, missing credentials, impossible action.
    case capability
    /// A flaky failure that may clear on its own.
    case transient
}

/// Status of one dispatch attempt. Matches the reference `task_runs.status`.
public enum CardRunStatus: String, Sendable, Codable {
    case running
    case done
    case blocked
    case crashed
    case timed_out
    case failed
    case released
}

/// Terminal classification of a run. Matches the reference
/// `task_runs.outcome` exactly.
public enum CardRunOutcome: String, Sendable, Codable {
    case completed
    case blocked
    case crashed
    case timed_out
    case spawn_failed
    case gave_up
    case reclaimed
}

/// Workspace anchoring, matching the reference `VALID_WORKSPACE_KINDS`.
public enum CardWorkspaceKind: String, Sendable, Codable, CaseIterable {
    case scratch
    case worktree
    case dir
}

/// The task row — concept-for-concept the reference `tasks` table.
public struct CardTask: Sendable, Codable, Identifiable, Equatable {
    public let id: String
    public var title: String
    public var body: String?
    public var assignee: String?
    public var status: CardStatus
    public var priority: Int
    public var createdBy: String?
    public var createdAt: Date
    public var startedAt: Date?
    public var completedAt: Date?
    public var workspaceKind: CardWorkspaceKind
    public var workspacePath: String?
    public var branchName: String?
    public var tenant: String?
    /// Legacy one-line result; modern handoffs live on the run (`summary`).
    public var result: String?
    public var idempotencyKey: String?
    /// Consecutive non-success counter; trips the circuit breaker at
    /// `CardRules.failureLimit`.
    public var consecutiveFailures: Int
    /// Short excerpt of the most recent failure's error text.
    public var lastFailureError: String?
    public var maxRuntimeSeconds: Int?
    public var lastHeartbeatAt: Date?
    /// Pointer to the currently-active run (nil when idle). Denormalized
    /// for cheap reads; must stay consistent with the run rows.
    public var currentRunID: String?
    /// The kind of the most recent block — preserved across unblock so a
    /// re-block loop is recognizable.
    public var blockKind: CardBlockKind?
    /// Unblock-loop breaker counter: incremented each time the task is
    /// re-blocked for the same kind after having been unblocked.
    public var blockRecurrences: Int
    public var modelOverride: String?
    public var skills: [String]

    public init(
        id: String = UUID().uuidString,
        title: String,
        body: String? = nil,
        assignee: String? = nil,
        status: CardStatus = .ready,
        priority: Int = 0,
        createdBy: String? = nil,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        workspaceKind: CardWorkspaceKind = .scratch,
        workspacePath: String? = nil,
        branchName: String? = nil,
        tenant: String? = nil,
        result: String? = nil,
        idempotencyKey: String? = nil,
        consecutiveFailures: Int = 0,
        lastFailureError: String? = nil,
        maxRuntimeSeconds: Int? = nil,
        lastHeartbeatAt: Date? = nil,
        currentRunID: String? = nil,
        blockKind: CardBlockKind? = nil,
        blockRecurrences: Int = 0,
        modelOverride: String? = nil,
        skills: [String] = []
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.assignee = assignee
        self.status = status
        self.priority = priority
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.workspaceKind = workspaceKind
        self.workspacePath = workspacePath
        self.branchName = branchName
        self.tenant = tenant
        self.result = result
        self.idempotencyKey = idempotencyKey
        self.consecutiveFailures = consecutiveFailures
        self.lastFailureError = lastFailureError
        self.maxRuntimeSeconds = maxRuntimeSeconds
        self.lastHeartbeatAt = lastHeartbeatAt
        self.currentRunID = currentRunID
        self.blockKind = blockKind
        self.blockRecurrences = blockRecurrences
        self.modelOverride = modelOverride
        self.skills = skills
    }

    /// True once the task can no longer gate children
    /// (reference: done/archived are the settled statuses).
    public var isSettled: Bool { status == .done || status == .archived }
}

/// One dispatch attempt — concept-for-concept the reference `task_runs`
/// table. Claim state, PID, heartbeat, runtime cap, and the structured
/// summary all live here. Multiple rows per task when the task was
/// retried after crash/timeout/block.
public struct CardRun: Sendable, Codable, Identifiable, Equatable {
    public let id: String
    public let taskID: String
    /// 1-based attempt number for the task.
    public let attempt: Int
    public var status: CardRunStatus
    public var startedAt: Date
    public var endedAt: Date?
    /// Terminal classification; nil while still running.
    public var outcome: CardRunOutcome?
    /// Structured handoff written on completion — becomes context for
    /// dependent tasks.
    public var summary: String?
    /// Free-form structured facts: changed_files, tests_run, findings…
    public var metadata: [String: String]?
    public var error: String?
    public var maxRuntimeSeconds: Int?
    public var lastHeartbeatAt: Date?
    public var profile: String?

    public init(
        id: String = UUID().uuidString,
        taskID: String,
        attempt: Int,
        status: CardRunStatus = .running,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        outcome: CardRunOutcome? = nil,
        summary: String? = nil,
        metadata: [String: String]? = nil,
        error: String? = nil,
        maxRuntimeSeconds: Int? = nil,
        lastHeartbeatAt: Date? = nil,
        profile: String? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.attempt = attempt
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcome = outcome
        self.summary = summary
        self.metadata = metadata
        self.error = error
        self.maxRuntimeSeconds = maxRuntimeSeconds
        self.lastHeartbeatAt = lastHeartbeatAt
        self.profile = profile
    }
}

/// A durable note on a task's thread (`task_comments`).
public struct CardComment: Sendable, Codable, Identifiable, Equatable {
    public let id: String
    public let taskID: String
    public let author: String
    public let body: String
    public let createdAt: Date

    public init(id: String = UUID().uuidString, taskID: String, author: String, body: String, createdAt: Date = Date()) {
        self.id = id
        self.taskID = taskID
        self.author = author
        self.body = body
        self.createdAt = createdAt
    }
}

/// A parent→child dependency edge (`task_links`).
public struct CardLink: Sendable, Codable, Equatable {
    public let parentID: String
    public let childID: String
    public let createdAt: Date

    public init(parentID: String, childID: String, createdAt: Date = Date()) {
        self.parentID = parentID
        self.childID = childID
        self.createdAt = createdAt
    }
}

/// An audit trail entry (`task_events`) — kind + payload + which run.
public struct CardEvent: Sendable, Codable, Identifiable, Equatable {
    public let id: String
    public let taskID: String
    public let runID: String?
    public let kind: String
    public let payload: String?
    public let createdAt: Date

    public init(id: String = UUID().uuidString, taskID: String, runID: String? = nil, kind: String, payload: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.taskID = taskID
        self.runID = runID
        self.kind = kind
        self.payload = payload
        self.createdAt = createdAt
    }
}

/// Metadata for a file attached to a task (`task_attachments`). The blob
/// lives on disk under the store's attachments root; this row carries
/// filename, absolute stored path, content type, and size so the worker
/// (and the web UI) can surface it.
public struct CardAttachment: Sendable, Codable, Identifiable, Equatable {
    public let id: String
    public let taskID: String
    public let filename: String
    public let storedPath: String
    public var contentType: String?
    public var size: Int?
    public let createdAt: Date

    public init(id: String = UUID().uuidString, taskID: String, filename: String, storedPath: String, contentType: String? = nil, size: Int? = nil, createdAt: Date = Date()) {
        self.id = id
        self.taskID = taskID
        self.filename = filename
        self.storedPath = storedPath
        self.contentType = contentType
        self.size = size
        self.createdAt = createdAt
    }
}

// ==========================================================================
// CardRules — pure transition logic shared by every store backend.
//
// Keeping the routing (block kinds, recompute, circuit breaker, loop
// breaker) as pure functions over the value types means the file store
// and the tessera store behave identically, and every rule is unit-
// testable without any I/O.
// ==========================================================================

public enum CardRules {
    /// Circuit breaker: consecutive non-successes before a task auto-blocks
    /// (reference `DEFAULT_FAILURE_LIMIT`).
    public static let failureLimit = 2
    /// Unblock-loop breaker: after this many re-blocks for the same kind,
    /// the task routes to `triage` instead of `blocked`
    /// (reference `BLOCK_RECURRENCE_LIMIT`).
    public static let blockRecurrenceLimit = 2

    // Context caps (reference _CTX_* constants).
    public static let contextMaxPriorAttempts = 10
    public static let contextMaxComments = 30
    public static let contextMaxFieldBytes = 4 * 1024
    public static let contextMaxBodyBytes = 8 * 1024
    public static let contextMaxCommentBytes = 2 * 1024

    /// Apply a block to `task` per the reference `block_task` routing:
    ///
    /// * `dependency` — never enters the human `blocked` bucket; routes to
    ///   `todo` and waits for `recomputeReady` to promote it when its
    ///   parents finish. No human, no cron, no retry storm.
    /// * `needs_input` / `capability` / `transient` / nil — lands in
    ///   `blocked` for a human. Each re-block for the SAME kind after
    ///   having been unblocked increments `blockRecurrences`; at
    ///   `blockRecurrenceLimit` the task routes to `triage` instead —
    ///   breaking the unblock↔re-block loop.
    ///
    /// Returns the updated task. The caller updates the run row.
    public static func block(_ task: CardTask, kind: CardBlockKind?) -> CardTask {
        var t = task
        t.currentRunID = nil
        if kind == .dependency {
            t.status = .todo
            t.blockKind = kind
            return t
        }
        // Loop breaker: same kind as the last block after an unblock.
        if let kind, t.blockKind == kind {
            t.blockRecurrences += 1
            if t.blockRecurrences >= blockRecurrenceLimit {
                t.status = .triage
                t.blockKind = kind
                return t
            }
        }
        t.status = .blocked
        t.blockKind = kind
        return t
    }

    /// Promote `todo` tasks to `ready` when all parents are done or
    /// archived (reference `recompute_ready`). Tasks in `blocked` stay
    /// there — worker-initiated blocks (`needs_input`, `capability`,
    /// `transient`) only clear via explicit unblock; dependency blocks
    /// never sat in `blocked` in the first place. Promotion is also
    /// refused when the circuit breaker has tripped, so a task that
    /// repeatedly exhausts its budget cannot spin forever.
    public static func isReadyForPromotion(_ task: CardTask, parents: [CardTask]) -> Bool {
        guard task.status == .todo else { return false }
        guard task.consecutiveFailures < failureLimit else { return false }
        guard !parents.isEmpty else { return true }
        return parents.allSatisfy { $0.status == .done || $0.status == .archived }
    }

    /// Apply a non-success outcome (`crashed` / `timed_out` / …) — the
    /// reference `_record_task_failure`. Increments the consecutive-failure
    /// counter, stamps `lastFailureError`, and auto-blocks when the
    /// counter reaches the failure limit. Returns the updated task and
    /// whether the breaker tripped (so the caller can route the run row).
    public static func recordFailure(_ task: CardTask, error: String?) -> (task: CardTask, tripped: Bool) {
        var t = task
        t.consecutiveFailures += 1
        t.lastFailureError = error.flatMap { String($0.prefix(512)) }
        t.currentRunID = nil
        if t.consecutiveFailures >= failureLimit {
            t = block(t, kind: nil)
            return (t, true)
        }
        // Back to dispatchable; the next claim retries.
        if t.status == .running { t.status = .ready }
        return (t, false)
    }

    /// Apply an explicit unblock (reference `unblock_task`): closed runs
    /// already handled by the caller; the task goes to `ready` when its
    /// parents are satisfied, else `todo` (re-gated by recompute).
    public static func unblock(_ task: CardTask, parents: [CardTask]) -> CardTask {
        var t = task
        t.currentRunID = nil
        if parents.allSatisfy({ $0.status == .done || $0.status == .archived }) || parents.isEmpty {
            t.status = .ready
        } else {
            t.status = .todo
        }
        return t
    }

    /// Reset the failure counter on successful completion.
    public static func complete(_ task: CardTask, result: String?) -> CardTask {
        var t = task
        t.status = .done
        t.completedAt = Date()
        t.currentRunID = nil
        t.result = result ?? t.result
        t.consecutiveFailures = 0
        t.lastFailureError = nil
        return t
    }

    /// Truncate a string to `limit` with a visible ellipsis (reference
    /// `_cap`).
    public static func cap(_ s: String?, _ limit: Int) -> String {
        guard var s, !s.isEmpty else { return "" }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count <= limit { return s }
        let head = String(s.prefix(limit))
        return head + "… [truncated, \(s.count - limit) chars omitted]"
    }
}
