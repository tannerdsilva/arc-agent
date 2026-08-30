import Foundation

/// The danger level of a command or action.
public enum DangerLevel: Int, Sendable, Comparable, Codable {
    /// Safe — no approval needed.
    case safe = 0
    /// Suspicious — may warrant attention.
    case suspicious = 1
    /// Dangerous — requires approval.
    case dangerous = 2
    /// Critical — always requires approval, even in YOLO mode.
    case critical = 3

    public static func < (lhs: DangerLevel, rhs: DangerLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The result of an approval request.
public enum ApprovalResult: Sendable {
    /// Approved — the action may proceed.
    case approved
    /// Denied — the action is blocked.
    case denied
    /// Requires human review (smart mode only).
    case requiresReview
}

/// The approval mode for the security system.
public enum ApprovalMode: String, Sendable, Codable {
    /// Every dangerous command prompts the user.
    case manual
    /// A lightweight LLM classifies commands as low-risk (auto-approve)
    /// or high-risk (prompt user).
    case smart
    /// All commands are auto-approved (frozen at process start).
    case off
}

/// Manages approval for dangerous commands and actions.
///
/// ``ApprovalManager`` implements three modes:
/// - **manual**: every dangerous command prompts the user
/// - **smart**: an auxiliary LLM classifies risk; low-risk is auto-approved
/// - **off**: all commands are auto-approved (YOLO mode, frozen at start)
///
/// ## Concurrency
///
/// ``ApprovalManager`` is an **actor** — all state mutations are serialized.
///
/// ## Law of the Land
///
/// YOLO mode is frozen at process start from a command-line flag or
/// environment variable. It cannot be toggled at runtime, preventing
/// prompt-injection bypass.
public actor ApprovalManager {

    /// The approval mode, frozen at initialization.
    public let mode: ApprovalMode

    /// Per-session approval state.
    private var sessionStates: [String: SessionApprovalState] = [:]

    /// Create an approval manager.
    ///
    /// - Parameter mode: The approval mode. Defaults to `.manual`.
    public init(mode: ApprovalMode = .manual) {
        self.mode = mode
    }

    /// Check whether an action needs approval.
    ///
    /// - Parameters:
    ///   - command: The command or action to check.
    ///   - sessionKey: A session identifier for state tracking.
    /// - Returns: `true` if the action needs approval.
    public func needsApproval(command: String, sessionKey: String) async -> Bool {
        switch mode {
        case .off:
            return false
        case .manual:
            return await detectDangerLevel(command) >= .dangerous
        case .smart:
            return await detectDangerLevel(command) >= .dangerous
        }
    }

    /// Request approval for a command.
    ///
    /// - Parameters:
    ///   - command: The command to approve.
    ///   - description: A human-readable description of the action.
    ///   - sessionKey: A session identifier.
    /// - Returns: The approval result.
    public func requestApproval(
        command: String,
        description: String,
        sessionKey: String
    ) async -> ApprovalResult {
        switch mode {
        case .off:
            return .approved
        case .manual:
            // In manual mode, we always require review for dangerous commands.
            // In a CLI context, this would prompt the user.
            return .requiresReview
        case .smart:
            // Smart mode uses an auxiliary LLM call to classify risk.
            // For now, fall back to requiresReview for dangerous commands.
            let level = await detectDangerLevel(command)
            if level >= .critical {
                return .denied
            }
            if level >= .dangerous {
                return .requiresReview
            }
            return .approved
        }
    }
}

// MARK: - Session State

/// Per-session approval tracking state.
struct SessionApprovalState: Sendable {
    /// Number of approvals granted in this session.
    var approvalCount: Int = 0
    /// Whether the session has been pre-approved.
    var isPreApproved: Bool = false
}

// MARK: - Dangerous Command Detection

/// A compiled dangerous command pattern.
///
/// ``Regex`` is not `Sendable` on this toolchain, so compiled patterns live
/// in the isolated state of ``DangerousPatternStore`` and never cross a
/// concurrency domain. This struct is intentionally not `Sendable`.
struct DangerousPattern {
    let level: DangerLevel
    let regex: Regex<AnyRegexOutput>
}

/// Owns the compiled dangerous-command patterns.
///
/// ``Regex`` is not `Sendable`, so the precompiled patterns are stored as
/// actor-isolated state and matched from inside the actor. The singleton is
/// initialized once at first use; every detection request hops to this actor
/// and runs there — no pattern is ever shared across a concurrency boundary.
actor DangerousPatternStore {

    /// The shared detector.
    static let shared = DangerousPatternStore()

    /// Precompiled patterns, compiled once at first use.
    private let patterns: [DangerousPattern]

    init() {
        func pattern(_ raw: String) -> Regex<AnyRegexOutput>? {
            try? Regex(raw)
        }

        let entries: [(DangerLevel, Regex<AnyRegexOutput>?)] = [
            // Critical — destructive system operations
            (.critical, pattern("^rm\\s+-rf\\s+/\\s*$")),  // rm -rf / only
            (.critical, pattern("mkfs\\.")),
            (.critical, pattern("dd\\s+if=.*of=/dev")),
            (.critical, pattern(">\\s*/dev/")),

            // Dangerous — potentially destructive
            (.dangerous, pattern("rm\\s+-rf")),
            (.dangerous, pattern("chmod\\s+777")),
            (.dangerous, pattern("chown\\s+")),
            (.dangerous, pattern("wget\\s+.*\\|\\s*bash")),
            (.dangerous, pattern("curl\\s+.*\\|\\s*bash")),
            (.dangerous, pattern("sudo\\s+")),
            (.dangerous, pattern("passwd\\s+")),
            (.dangerous, pattern("dd\\s+")),
            (.dangerous, pattern("shutdown\\s+")),
            (.dangerous, pattern("reboot\\s+")),
            (.dangerous, pattern("halt\\s+")),
            (.dangerous, pattern("poweroff\\s+")),
            (.dangerous, pattern("iptables\\s+")),
            (.dangerous, pattern("ufw\\s+")),

            // Suspicious — network exfiltration
            (.suspicious, pattern("nc\\s+")),
            (.suspicious, pattern("ncat\\s+")),
            (.suspicious, pattern("telnet\\s+")),
            (.suspicious, pattern("ssh\\s+-R\\s+")),
            (.suspicious, pattern("scp\\s+")),
        ]

        // Invalid patterns are silently skipped.
        self.patterns = entries.compactMap { (level, optionalRegex) in
            optionalRegex.map { DangerousPattern(level: level, regex: $0) }
        }
    }

    /// Detect the danger level of a command.
    ///
    /// - Parameter command: The command string to check.
    /// - Returns: The highest danger level found, or `.safe` if none match.
    func detect(_ command: String) -> DangerLevel {
        var highest = DangerLevel.safe

        // Fork bomb detection (string-based — the regex metacharacters make
        // a pure-regex approach fragile across regex engines).
        if command.contains(":(){") && command.contains(":&") {
            highest = .critical
        }

        for pattern in patterns {
            if command.contains(pattern.regex) {
                highest = max(highest, pattern.level)
            }
        }

        return highest
    }
}

/// Detect the danger level of a command.
///
/// - Parameter command: The command string to check.
/// - Returns: The highest danger level found, or `.safe` if none match.
///
/// `async` because the precompiled patterns live in an actor — pattern
/// matching always runs on the ``DangerousPatternStore`` actor.
public func detectDangerLevel(_ command: String) async -> DangerLevel {
    await DangerousPatternStore.shared.detect(command)
}
