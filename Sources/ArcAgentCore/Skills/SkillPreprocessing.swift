import Foundation

// MARK: - Skill preprocessing (Hermes `skill_preprocessing.py`)

/// Template variables + inline shell execution in skill content, applied at
/// load time (the agent sees the EXPANDED skill, not the raw file).
public enum SkillPreprocessing {

    public static let maxInlineOutputBytes = 4_000
    public static let inlineCommandTimeoutSeconds = 10.0

    /// Expand `${HERMES_SKILL_DIR}` and `${HERMES_SESSION_ID}` template
    /// variables (Hermes supports these two plus environment passthrough).
    public static func expandTemplates(_ content: String, skillDir: URL?, sessionID: String) -> String {
        var result = content
        if let skillDir {
            result = result.replacingOccurrences(of: "${HERMES_SKILL_DIR}", with: skillDir.path)
        }
        result = result.replacingOccurrences(of: "${HERMES_SESSION_ID}", with: sessionID)
        for (key, value) in ProcessInfo.processInfo.environment {
            result = result.replacingOccurrences(of: "${\(key)}", with: value)
        }
        return result
    }

    /// Execute inline `!`cmd`` blocks in skill content (Hermes runs them at
    /// load; output is capped at 4000 bytes and substituted back).
    ///
    /// An inline block is a backtick span immediately preceded by `!`
    /// (`!`command``). Plain backtick spans stay verbatim.
    public static func runInlineCommands(_ content: String) async throws -> String {
        let chars = Array(content)
        var result = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "`" {
                let isInline = i > 0 && chars[i - 1] == "!"
                // Find the closing backtick.
                var j = i + 1
                while j < chars.count && chars[j] != "`" { j += 1 }
                if j >= chars.count {
                    // Unterminated: keep the raw text as-is.
                    result += String(chars[i...])
                    return result
                }
                let span = String(chars[(i + 1)..<j])
                if isInline {
                    // Drop the leading "!" already captured into result.
                    result = String(result.dropLast())
                    let output = try await runShell(span.trimmingCharacters(in: .whitespaces))
                    result += output
                } else {
                    result += "`\(span)`"
                }
                i = j + 1
            } else {
                result.append(chars[i])
                i += 1
            }
        }
        return result
    }

    /// Run one shell command via /bin/sh, capturing stdout, capped at
    /// `maxInlineOutputBytes`, with a hard timeout.
    public static func runShell(_ command: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        try process.run()

        let output = try await readBytes(pipe: outputPipe, cap: maxInlineOutputBytes)
        // Wait with a bounded timeout (Law: no threads — timeout via task race).
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { process.waitUntilExit() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(inlineCommandTimeoutSeconds * 1_000_000_000))
                process.terminate()
                throw CuratorError.backupFailed("inline command timed out: \(command.prefix(80))")
            }
            _ = try? await group.next()
            group.cancelAll()
        }
        return output
    }

    /// Read a pipe's bytes with a cap (Foundation AsyncBytes; no threads).
    static func readBytes(pipe: Pipe, cap: Int) async throws -> String {
        var collected = Data()
        for try await byte in pipe.fileHandleForReading.bytes {
            collected.append(byte)
            if collected.count >= cap { break }
        }
        return String(data: collected, encoding: .utf8) ?? ""
    }

    /// Full preprocessing pipeline: templates, then inline commands.
    public static func preprocess(
        _ content: String,
        skillDir: URL?,
        sessionID: String
    ) async throws -> String {
        let expanded = expandTemplates(content, skillDir: skillDir, sessionID: sessionID)
        return try await runInlineCommands(expanded)
    }
}
