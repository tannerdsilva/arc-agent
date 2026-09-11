import Foundation

// MARK: - Verification evidence (Hermes `verification_evidence.py`)

/// Evidence attached to terminal-tool results so the agent can verify its own
/// work: command, cwd, exit code, truncation flag, and changed paths. Also
/// builds the Hermes "verify on stop" nudge when many files changed.
public struct ToolEvidence: Sendable, Equatable, Codable {
    public let command: String
    public let cwd: String
    public let exitCode: Int32
    public let truncated: Bool
    public let changedPaths: [String]

    public init(command: String, cwd: String, exitCode: Int32, truncated: Bool, changedPaths: [String]) {
        self.command = command
        self.cwd = cwd
        self.exitCode = exitCode
        self.truncated = truncated
        self.changedPaths = changedPaths
    }

    /// Attach the evidence block to a terminal tool result (Hermes appends
    /// evidence to the tool result JSON).
    public func attach(to result: String) -> String {
        var lines = [result]
        if !command.isEmpty {
            lines.append("\n[evidence] command: \(command)")
        }
        if !cwd.isEmpty {
            lines.append("[evidence] cwd: \(cwd)")
        }
        lines.append("[evidence] exit: \(exitCode)")
        if truncated {
            lines.append("[evidence] output truncated")
        }
        if !changedPaths.isEmpty {
            lines.append("[evidence] changed paths (\(changedPaths.count)): \(changedPaths.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }
}

public enum Verification {
    /// Hermes verify-on-stop threshold: nudge the model when more than this
    /// many paths changed (it should re-run tests / inspect the diff).
    public static let maxChangedPaths = 8
    /// Changed paths that are not worth verifying (build artifacts, lockfiles).
    static let ignorePatterns = [
        #"\.build/"#, #"node_modules/"#, #"\.git/"#,
        #"Package\.resolved"#, #"\.DS_Store"#,
        #"\.o$"#, #"\.a$"#, #"\.dylib$"#, #"\.xctest"#,
    ]

    /// Filter changed paths to the ones worth verifying (Hermes
    /// `filter_non_code_change_paths`).
    public static func verifyWorthyPaths(_ paths: [String]) -> [String] {
        paths.filter { path in
            !ignorePatterns.contains { pattern in
                (try? NSRegularExpression(pattern: pattern))?.firstMatch(
                    in: path, range: NSRange(location: 0, length: (path as NSString).length)) != nil
            }
        }
    }

    /// Build the verify nudge appended to the turn when the threshold is hit
    /// (Hermes `verify_on_stop` message).
    public static func verifyNudge(changedPaths: [String]) -> String {
        let worthy = verifyWorthyPaths(changedPaths)
        guard worthy.count > maxChangedPaths else { return "" }
        let list = worthy.prefix(12).joined(separator: ", ")
        return "Verification: \(worthy.count) files changed (\(list), ...). " +
               "Run tests or inspect the diff before declaring the task complete."
    }
}

// MARK: - Background review (Hermes `background_review.py`)

/// Periodic background review of recent tool calls by an auxiliary model:
/// detects loops, wasted work, and policy slips, then injects guidance into
/// the NEXT turn. Cadence is config-driven (every N tool calls).
public struct BackgroundReview { // swiftlint:disable:this type_name
    public struct Settings: Sendable {
        /// Review after this many tool calls (0/disabled by default).
        public var afterToolCalls: Int
        /// How many of the most recent calls to include in a review pass.
        public var window: Int
        public init(afterToolCalls: Int = 0, window: Int = 8) {
            self.afterToolCalls = afterToolCalls
            self.window = window
        }
    }

    public static let maxReviewBatch = 12

    /// The review prompt (Hermes background review: ask for concise,
    /// actionable observations — no fluff).
    public static func reviewPrompt(toolCalls: [String]) -> String {
        """
        Review the recent tool calls for wasted work, loops, or policy issues. \
        Be concise. If there is nothing wrong, respond with exactly "OK". If \
        there is a problem, name the specific calls and say what to do instead.

        Recent tool calls:
        \(toolCalls.map { "- \($0)" }.joined(separator: "\n"))
        """
    }

    /// Decision: whether a review is due given the running tool-call count
    /// (Hermes cadence check).
    public static func isDue(settings: Settings, totalToolCalls: Int) -> Bool {
        guard settings.afterToolCalls > 0 else { return false }
        return totalToolCalls > 0 && totalToolCalls % settings.afterToolCalls == 0
    }

    /// Guidance block injected into the next turn (only when review found an
    /// issue; "OK" reviews inject nothing).
    public static func guidanceBlock(_ modelResponse: String) -> String? {
        let trimmed = modelResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "OK" || trimmed == "ok" {
            return nil
        }
        return "<background-review>\n\(trimmed)\n</background-review>"
    }
}
