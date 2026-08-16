import Foundation

/// The `terminal` tool: executes a shell command and returns its output.
///
/// Uses Foundation's `Process` for command execution. Supports both foreground
/// (wait for completion) and background (return immediately with a session ID)
/// modes via the `background` parameter.
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
            let command: String = try Self.required(args, key: "command")
            let timeout: Int = (args["timeout"] as? Int) ?? 180
            let workdir: String? = args["workdir"] as? String
            let background: Bool = (args["background"] as? Bool) ?? false
            return try await Self.runCommand(command: command, timeout: timeout, workdir: workdir, background: background)
        },
        emoji: "💻"
    )

    // MARK: - Handler

    private static func runCommand(
        command: String,
        timeout: Int,
        workdir: String?,
        background: Bool
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]

        if let workdir {
            process.currentDirectoryURL = URL(fileURLWithPath: workdir)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if background {
            try process.run()
            let pid = process.processIdentifier
            return "Background process started with PID: \(pid)"
        }

        // Wait for completion using a checked continuation bridged from
        // Process.terminationHandler — no blocking on the cooperative pool.
        let exitCode = try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                    process.terminationHandler = { proc in
                        continuation.resume(returning: proc.terminationStatus)
                    }
                    do {
                        try process.run()
                    } catch {
                        // If run() throws, the handler will never fire.
                        continuation.resume(throwing: error)
                    }
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
                process.terminate()
                throw TerminalError.timeout(timeout)
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        let exitCodeInt = exitCode

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

    var description: String {
        switch self {
        case .timeout(let seconds):
            return "Command timed out after \(seconds) seconds."
        }
    }
}
