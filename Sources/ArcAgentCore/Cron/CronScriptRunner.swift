import Foundation
import SwiftSlash

// MARK: - Script jobs (plan Phase 6.2 — `no_agent` mode)
//
// `job.script != nil` bypasses the LLM entirely: the shell line IS the job.
// Watchdog contract — stdout becomes the delivered output, **silence stays
// silent** (empty stdout + exit 0 produces no delivered text), and a
// non-zero exit or timeout turns the error into the output (the alert).
// A silent-but-ok run still writes an "ok" history record so `history`
// shows it ran; it just doesn't page anyone.

/// Runs one cron script line and normalizes the outcome into
/// ``CronRunResult`` semantics (output + a synthetic delivery hint).
public enum CronScriptRunner {

    /// The result of one script execution.
    public struct Outcome: Sendable, Equatable {
        /// The text to record/deliver. Nil = silent success (empty stdout,
        /// exit 0) — the job ran, nothing to say.
        public let output: String?
        /// True when the run FAILED (non-zero exit or timeout) and the
        /// output is an alert rather than data.
        public let failed: Bool
    }

    /// Execute `script` via `/bin/bash -c` with a wall-clock timeout.
    ///
    /// - Parameters:
    ///   - script: a single shell line. NOT a heredoc — the job field is
    ///     one line by contract (multi-line logic belongs in a script file
    ///     the line invokes).
    ///   - timeoutSeconds: wall-clock cap. Default 60; the caller passes
    ///     config overrides. On timeout the process GROUP is killed by
    ///     SwiftSlash and the timeout text becomes the alert.
    public static func run(script: String, timeoutSeconds: Int = 60) async -> Outcome {
        var command = Command(absolutePath: Path("/bin/bash"), arguments: ["-c", script])
        command.inheritCurrentEnvironment()
        do {
            let outcome = try await SubprocessRunner.runBytes(command, timeout: TimeInterval(timeoutSeconds))
            let stdout = String(data: outcome.stdout, encoding: .utf8) ?? ""
            let stderr = String(data: outcome.stderr, encoding: .utf8) ?? ""
            if outcome.timedOut {
                return Outcome(output: "script timeout after \(timeoutSeconds)s: \(script.prefix(120))", failed: true)
            }
            if outcome.exitCodeValue != 0 {
                var text = "script failed (exit \(outcome.exitCodeValue))"
                if !stdout.isEmpty { text += "\n\(stdout)" }
                if !stderr.isEmpty { text += "\nstderr: \(stderr)" }
                return Outcome(output: text, failed: true)
            }
            let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return Outcome(output: nil, failed: false)  // silence stays silent
            }
            return Outcome(output: trimmed, failed: false)
        } catch {
            return Outcome(output: "script error: \(error.localizedDescription)", failed: true)
        }
    }
}
