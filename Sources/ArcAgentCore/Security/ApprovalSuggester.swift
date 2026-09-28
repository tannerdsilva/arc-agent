import Foundation

// MARK: - Approval suggestions (Hermes `hermes_cli/approvals_suggest.py`)

/// Mines session history for terminal commands that were *approved* (or
/// implicitly allowed) and proposes safety-allowlist entries.
///
/// Mirrors Hermes `hermes approvals suggest`:
/// - only repeatedly used commands qualify (default threshold: 3),
/// - already-allowed, unsafe-class and hardline-critical commands are never
///   proposed,
/// - nothing is applied until the user runs `--apply`.
public enum ApprovalSuggester {

    /// Commands whose use implies something Hermes declines to auto-allow:
    /// destructive ops, privilege escalation, remote execution, process
    /// control and system mutation. Conservative — when in doubt, exclude.
    static let unsafeClassPatterns: [String] = [
        #"^\s*rm\b"#, #"\brm -rf\b"#, #"^\s*sudo\b"#, #"\bsudo\b"#,
        #"\bchmod\b"#, #"\bchown\b"#, #"\bkill\b"#, #"\bpkill\b"#,
        #"\bdd\b(?!\s+of=)"#, #"\bshutdown\b"#, #"\breboot\b"#, #"\bhalt\b"#,
        #"\bmkfs"#, #"\bdiskutil erase"#, #"\bformat "#, #"\bfdisk\b"#,
        #"\bpasswd\b"#, #"\buserdel\b"#, #"\bgroupdel\b"#, #"\bapt-get purge\b"#,#"\bgit reset --hard\b"#, #"\bgit clean -f"#,
        #"\bssh\b"#, #"\bscp\b"#, #"\bcurl\b.*\|\s*(sh|bash)"#, #"\bsource\b.*\.env"#,
        #"\bsystemctl"#, #"\blaunchctl"#, #"\bdefaults write\b"#, #"\bplutil -replace"#,
        #"\bsecurity delete"#, #"\brm -i\b"#,
    ]

    /// A proposed allowlist entry.
    public struct Proposal: Sendable, Equatable {
        /// The exact command as recorded (trimmed, single line).
        public let command: String
        /// How many times it was recorded without a denial.
        public let approvals: Int
        /// The danger level the classifier assigned (for display).
        public let level: DangerLevel

        public init(command: String, approvals: Int, level: DangerLevel) {
            self.command = command
            self.approvals = approvals
            self.level = level
        }
    }

    /// Scan sessions for approved terminal commands and propose allowlist
    /// entries. `alwaysAllowed` commands are excluded; commands whose
    /// tool-result mentions a denial are excluded.
    public static func analyze(
        sessions: [Session],
        minFrequency: Int = 3,
        alwaysAllowed: Set<String> = []
    ) async -> [Proposal] {
        var levels: [String: DangerLevel] = [:]
        var frequencies: [String: Int] = [:]

        for session in sessions {
            // Index tool responses by call id (they may precede their use).
            var responses: [String: String] = [:]
            for msg in session.messages where msg.role == .tool {
                if let id = msg.toolCallID, let content = msg.content {
                    responses[id] = content
                }
            }
            for msg in session.messages where msg.role == .assistant {
                for call in msg.toolCalls ?? [] where call.function.name == "terminal" {
                    let command = extractCommand(from: call.function.arguments)
                    guard !command.isEmpty,
                          !alwaysAllowed.contains(command) else { continue }
                    // Denied/blocked commands never count as approvals.
                    if let result = responses[call.id], resultContainsDenial(result) {
                        continue
                    }
                    frequencies[command, default: 0] += 1
                    if levels[command] == nil {
                        levels[command] = await detectDangerLevel(command)
                    }
                }
            }
        }

        let proposals = frequencies.compactMap { command, freq -> Proposal? in
            guard freq >= max(1, minFrequency) else { return nil }
            guard let level = levels[command],
                  level >= .dangerous, level < .critical,
                  !matchesUnsafeClass(command) else { return nil }
            return Proposal(command: command, approvals: freq, level: level)
        }
        return proposals.sorted { $0.approvals > $1.approvals }
    }

    /// Extract the `command` argument from a JSON-encoded arguments blob.
    static func extractCommand(from argumentsJSON: String) -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = obj["command"] as? String else { return "" }
        return command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// Denial markers produced by the approval flow in arc's TerminalTool /
    /// ArcAgent (see `Sources/ArcAgentCore/Agent/ArcAgent.swift`).
    static func resultContainsDenial(_ result: String) -> Bool {
        let markers = [
            "Command blocked by security policy",
            "requires manual approval",
            "Blocked by security policy",
            "Denied by user",
        ]
        return markers.contains { result.contains($0) }
    }

    static func matchesUnsafeClass(_ command: String) -> Bool {
        unsafeClassPatterns.contains { pattern in
            command.range(of: pattern, options: .regularExpression) != nil
        }
    }

    /// Render the proposal table (Hermes-style, but plain).
    public static func render(_ proposals: [Proposal]) -> String {
        guard !proposals.isEmpty else {
            return "No approval-worthy command patterns found.\n"
                + "Use more sessions (or lower --min) to surface candidates from approved commands."
        }
        var lines = ["Approval suggest — proposed always-allow entries (most frequent first):", ""]
        for p in proposals {
            lines.append(String(format: "  %4d×  %@", p.approvals, p.command))
        }
        lines.append("")
        lines.append("Run `arc approvals suggest --apply` to write these into config.json "
            + "security.alwaysAllowedCommands (no command is applied until you run it).")
        return lines.joined(separator: "\n")
    }
}
