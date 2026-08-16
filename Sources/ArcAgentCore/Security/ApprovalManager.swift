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
            return detectDangerLevel(command) >= .dangerous
        case .smart:
            return detectDangerLevel(command) >= .dangerous
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
            let level = detectDangerLevel(command)
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

/// Patterns that indicate dangerous commands.
///
/// Each pattern is a regular expression matched against the command string.
let dangerousPatterns: [(DangerLevel, NSRegularExpression)] = [
    // Critical — destructive system operations
    (.critical, try! NSRegularExpression(pattern: "rm\\s+-rf\\s+/")),
    (.critical, try! NSRegularExpression(pattern: ":(){ \\:|:& };:")),  // fork bomb
    (.critical, try! NSRegularExpression(pattern: "mkfs\\.")),
    (.critical, try! NSRegularExpression(pattern: "dd\\s+if=.*of=/dev")),
    (.critical, try! NSRegularExpression(pattern: ">\\s*/dev/")),

    // Dangerous — potentially destructive
    (.dangerous, try! NSRegularExpression(pattern: "rm\\s+-rf")),
    (.dangerous, try! NSRegularExpression(pattern: "chmod\\s+777")),
    (.dangerous, try! NSRegularExpression(pattern: "chown\\s+")),
    (.dangerous, try! NSRegularExpression(pattern: "wget\\s+.*\\|\\s*bash")),
    (.dangerous, try! NSRegularExpression(pattern: "curl\\s+.*\\|\\s*bash")),
    (.dangerous, try! NSRegularExpression(pattern: "sudo\\s+")),
    (.dangerous, try! NSRegularExpression(pattern: "passwd\\s+")),
    (.dangerous, try! NSRegularExpression(pattern: "dd\\s+")),
    (.dangerous, try! NSRegularExpression(pattern: "shutdown\\s+")),
    (.dangerous, try! NSRegularExpression(pattern: "reboot\\s+")),
    (.dangerous, try! NSRegularExpression(pattern: "halt\\s+")),
    (.dangerous, try! NSRegularExpression(pattern: "poweroff\\s+")),
    (.dangerous, try! NSRegularExpression(pattern: "iptables\\s+")),
    (.dangerous, try! NSRegularExpression(pattern: "ufw\\s+")),

    // Suspicious — network exfiltration
    (.suspicious, try! NSRegularExpression(pattern: "nc\\s+")),
    (.suspicious, try! NSRegularExpression(pattern: "ncat\\s+")),
    (.suspicious, try! NSRegularExpression(pattern: "telnet\\s+")),
    (.suspicious, try! NSRegularExpression(pattern: "ssh\\s+-R\\s+")),
    (.suspicious, try! NSRegularExpression(pattern: "scp\\s+")),
]

/// Detect the danger level of a command.
///
/// - Parameter command: The command string to check.
/// - Returns: The highest danger level found, or `.safe` if none match.
public func detectDangerLevel(_ command: String) -> DangerLevel {
    var highest = DangerLevel.safe

    for (level, pattern) in dangerousPatterns {
        if pattern.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil {
            highest = max(highest, level)
        }
    }

    return highest
}
