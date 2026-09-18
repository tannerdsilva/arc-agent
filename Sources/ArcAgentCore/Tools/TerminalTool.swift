import Foundation
import SwiftSlash

/// The `terminal` tool: executes a shell command and returns its output.
///
/// Foreground execution uses SwiftSlash (`SubprocessRunner`): posix_spawn,
/// concurrent byte-exact capture, process-group kill on timeout. Background
/// mode (detached start, return PID immediately) stays on Foundation
/// `Process` because SwiftSlash has no detached-launch API — documented
/// exception.
///
/// ## Parameters
/// - `command`: The shell command to execute.
/// - `timeout`: (Optional) Max seconds to wait. Default 180.
/// - `workdir`: (Optional) Working directory for the command.
/// - `background`: (Optional) Run in background. Default false.
///
/// ## Returns
/// The command's stdout + stderr, exit code, and any error message.
public enum TerminalTool {

    /// The ``ToolEntry`` for this tool.
    public static let entry = ToolEntry(
        name: "terminal",
        toolset: "terminal",
        description: "Execute a shell command and return its output. "
            + "Use for builds, installs, git, scripts, and any command-line tool.",
        schema: .object(
            description: "Execute a shell command",
            properties: [
                "command": .string(description: "The shell command to execute"),
                "timeout": .integer(description: "Max seconds to wait", default: 180),
                "workdir": .string(description: "Working directory (absolute path)"),
                "background": .boolean(description: "Run in background", default: false),
            ],
            required: ["command"]
        ),
        handler: { args in
            if let refusal = Self.lockdownRefusal(command: (args["command"] as? String) ?? "") {
                return "Error: " + refusal
            }
            let command: String = try Self.required(args, key: "command")
            let timeout: Int = (args["timeout"] as? Int) ?? 180
            let workdir: String? = args["workdir"] as? String
            let background: Bool = (args["background"] as? Bool) ?? false
            return try await Self.runCommand(command: command, timeout: timeout, workdir: workdir, background: background)
        },
        emoji: "💻"
    )

    /// Best-effort lockdown guard: refuse clearly-mutating commands that
    /// target locked surfaces (skills directory tree or locked profile
    /// files). Read-only references (cat/grep/ls) pass through.
    static func lockdownRefusal(command: String) -> String? {
        let lower = command.lowercased()
        // Write-ish markers only — never block reads.
        let looksWritable = lower.contains(">") || lower.contains("tee ") || lower.contains("sed -i")
            || lower.contains("perl -i") || lower.contains("mv ") || lower.contains("cp ")
            || lower.contains("rm ") || lower.contains("touch ") || lower.contains("mkdir")
        guard looksWritable else { return nil }

        let skillsPath = AgentPowers.skillsDirectory.path
        if command.contains(skillsPath) || command.contains("/.arc/skills/") {
            if !AgentPowers.canManageSkills() {
                return "Refused: writes under the skills directory are locked in Settings "
                    + "(Agent powers → Skills). Use skill_creation / skill_edit while unlocked."
            }
            for locked in AgentPowers.config.lockedSkills {
                if command.contains("/\(locked)/") {
                    return "Refused: skill '\(locked)' is locked in Settings "
                        + "(Agent powers → Skills). Use skill_edit after unlocking."
                }
            }
        }
        let files: [(String, String)] = [
            ("MEMORY.md", "memory"), ("USER.md", "user"),
            ("SOUL.md", "soul"), ("AGENTS.md", "agents"),
        ]
        for (filename, key) in files where command.contains(filename) {
            if let refusal = AgentPowers.profileWriteRefusal(file: key) {
                return refusal
            }
        }
        return nil
    }

    // MARK: - Handler

    private static func runCommand(
        command: String,
        timeout: Int,
        workdir: String?,
        background: Bool
    ) async throws -> String {
        // Background mode: SwiftSlash has no detached-launch API (its run()
        // always waits, then reaps), so this path keeps Foundation Process —
        // documented exception alongside Tessera/storage internals.
        if background {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", command]
            if let workdir {
                process.currentDirectoryURL = URL(fileURLWithPath: workdir)
            }
            try process.run()
            let pid = process.processIdentifier
            return "Background process started with PID: \(pid)"
        }

        // Foreground: SwiftSlash. Byte-exact capture (BYO pipes, drained
        // concurrently — no pipe-buffer deadlock on large outputs) and
        // process-group kill on timeout with full reaping.
        var shellCommand = Command(absolutePath: Path("/bin/bash"), arguments: ["-c", command])
        shellCommand.inheritCurrentEnvironment()
        if let workdir {
            shellCommand.workingDirectory = Path(workdir)
        }

        let outcome = try await SubprocessRunner.runBytes(
            shellCommand, timeout: TimeInterval(timeout))
        if outcome.timedOut {
            throw TerminalError.timeout(timeout)
        }

        let stdout = String(data: outcome.stdout, encoding: .utf8) ?? ""
        let stderr = String(data: outcome.stderr, encoding: .utf8) ?? ""
        let exitCodeInt = outcome.exitCodeValue

        var parts: [String] = []
        if !stdout.isEmpty { parts.append(stdout) }
        if !stderr.isEmpty { parts.append("stderr:\n\(stderr)") }
        parts.append("exit_code: \(exitCodeInt)")

        return parts.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func required<T>(_ args: [String: Any], key: String) throws -> T {
        guard let value = args[key] as? T else {
            throw ToolError.missingParameter(key)
        }
        return value
    }
}

// MARK: - Errors

enum TerminalError: Error, Sendable, CustomStringConvertible {
    case timeout(Int)
    case noResult

    var description: String {
        switch self {
        case .timeout(let seconds):
            return "Command timed out after \(seconds) seconds"
        case .noResult:
            return "Command produced no result"
        }
    }
}
