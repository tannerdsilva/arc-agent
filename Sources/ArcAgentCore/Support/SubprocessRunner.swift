import Foundation
import SwiftSlash
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - SubprocessRunner (SwiftSlash-backed)

/// Outcome of a bounded subprocess run through ``SubprocessRunner``.
public struct SubprocessOutcome: Sendable {
    /// Captured stdout. Reconstructed from SwiftSlash's line channel (lines
    /// joined with `\n`); a trailing newline in the raw output is absorbed by
    /// the line parser, so reconstructing is byte-identical except for one
    /// optional trailing `\n` after the final line.
    public let stdout: Data
    /// Captured stderr (same reconstruction semantics as ``stdout``).
    public let stderr: Data
    /// Exit code when the process exited normally; nil when signal-terminated.
    public let exitCode: Int32?
    /// Signal that terminated the process (nil when exited normally).
    public let signal: Int32?
    /// The run was stopped by the timeout (process group killed with SIGTERM).
    public let timedOut: Bool
    /// Captured stdout hit the cap.
    public let stdoutTruncated: Bool
    /// Captured stderr hit the cap.
    public let stderrTruncated: Bool

    public var exitCodeValue: Int32 { exitCode ?? -1 }
}

/// Errors surfaced by the subprocess runner.
public enum SubprocessError: Error, Sendable, CustomStringConvertible {
    case timeout(TimeInterval)
    case spawnFailed(String)

    public var description: String {
        switch self {
        case .timeout(let seconds):
            return "Command timed out after \(seconds) seconds"
        case .spawnFailed(let message):
            return "Failed to start command: \(message)"
        }
    }
}

/// Concurrency-safe subprocess execution on top of SwiftSlash
/// (posix_spawn + async reaping + process-group cancellation).
///
/// Design notes:
/// - Output is captured **concurrently** through SwiftSlash's built-in line
///   channels (newline-separated byte segments), so large outputs cannot
///   deadlock the child on a full pipe buffer. Bytes are reconstructed by
///   joining segments with `\n` (the library's own `runSync` semantics).
///   BYO (caller-owned pipe) channels were evaluated and rejected: the new
///   BYO path wedges the process-exit monitor when several children exit
///   concurrently (missing kqueue `EVFILT_PROC` event → zombie + hang).
///   The built-in path is SwiftSlash's long-standing tested code.
/// - **Timeout = process-group kill**: cancelling the run task signals the
///   child's entire process group (SwiftSlash `run(cancellationSignal:)`),
///   then reaps — no orphaned processes.
public enum SubprocessRunner {

    /// Default bytes captured per stream.
    public static let defaultCaptureCap = 8_000_000

    /// The separator byte SwiftSlash's built-in stdout/stderr channels
    /// segment on. A NUL is never produced by text output, so segments are
    /// effectively raw byte chunks — reconstruction re-inserts the separator
    /// between segments and is byte-exact for any output that does not end
    /// in a NUL (which covers all terminal/JSON/tool text).
    static let streamSeparator: [UInt8] = [0x00]

    /// Run `command` to completion, capturing stdout/stderr with a bounded
    /// capture and (optional) hard timeout.
    /// - Parameters:
    ///   - command: The SwiftSlash command to run. Callers that want the
    ///     parent environment must call `command.inheritCurrentEnvironment()`
    ///     first (SwiftSlash passes the env dict verbatim; an empty dict
    ///     spawns the child with no environment at all).
    ///   - timeout: Hard timeout in seconds. On expiry the child's process
    ///     group is killed with SIGTERM and `timedOut` is set. nil = no limit.
    ///   - captureCap: Bytes captured per stream; excess is discarded.
    ///   - stdin: Optional payload written to the child's stdin (queued in
    ///     the SwiftSlash writer FIFO pre-launch, then EOF-signaled).
    public static func runBytes(
        _ command: Command,
        timeout: TimeInterval? = nil,
        captureCap: Int = defaultCaptureCap,
        stdin: [UInt8]? = nil
    ) async throws -> SubprocessOutcome {
        var dataChannels: [Int32: DataChannel] = [
            STDOUT_FILENO: .write(.toParentProcess(stream: .init(), separator: streamSeparator)),
            STDERR_FILENO: .write(.toParentProcess(stream: .init(), separator: streamSeparator)),
        ]
        if stdin == nil {
            dataChannels[STDIN_FILENO] = .read(.fromNull)
        } else {
            dataChannels[STDIN_FILENO] = .read(.fromParentProcess(stream: .init()))
        }

        let child = ChildProcess(command, dataChannels: dataChannels)

        // Payload to stdin is queued in the writer FIFO (non-blocking yield;
        // `write` would await a flush future that only completes once the
        // writer loop starts at launch — a pre-launch deadlock) and signaled
        // EOF; the writer loop flushes the queue at spawn, then closes.
        if let stdin {
            try child.stdin.yield(stdin)
            child.stdin.closeDataChannel()
        }

        let drainOut = Task { await drain(child.stdout, cap: captureCap) }
        let drainErr = Task { await drain(child.stderr, cap: captureCap) }

        let (exit, timedOut) = try await runWithTimeout(child, timeout: timeout)

        let out = await drainOut.value
        let err = await drainErr.value

        let exitCode: Int32?
        let signal: Int32?
        switch exit {
        case .code(let c): exitCode = c; signal = nil
        case .signal(let s): exitCode = nil; signal = s
        }

        return SubprocessOutcome(
            stdout: out.data,
            stderr: err.data,
            exitCode: exitCode,
            signal: signal,
            timedOut: timedOut,
            stdoutTruncated: out.truncated,
            stderrTruncated: err.truncated)
    }

    // MARK: - Internals

    private enum RunSignal: Sendable {
        case exit(ChildProcess.Exit)
        case timeout
    }

    /// Race `child.run()` against a timeout. On timeout the run task is
    /// cancelled, which makes SwiftSlash signal the child's process group and
    /// reap it before the run task returns.
    static func runWithTimeout(
        _ child: ChildProcess,
        timeout: TimeInterval?
    ) async throws -> (exit: ChildProcess.Exit, timedOut: Bool) {
        guard let timeout else {
            return (try await child.run(cancellationSignal: SIGTERM), false)
        }
        let first = try await withThrowingTaskGroup(of: RunSignal.self) { group in
            group.addTask {
                do {
                    return .exit(try await child.run(cancellationSignal: SIGTERM))
                } catch is CancellationError {
                    // Signalled + reaped by the cancellation handler.
                    return .exit(.signal(SIGTERM))
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return .timeout
            }
            let winner = try await group.next()!
            group.cancelAll()
            // Let the loser finish (reap completes; sleep throws cancelled).
            _ = try? await group.next()
            return winner
        }
        switch first {
        case .exit(let exit):
            return (exit, false)
        case .timeout:
            return (.signal(SIGTERM), true)
        }
    }

    /// Drain a stream channel to completion, collecting at most `cap` bytes.
    /// Segments (which exclude the separator) are re-joined with the
    /// separator between them, which — with the NUL separator — is
    /// byte-exact for text output. Beyond-cap segments are still consumed
    /// (discarded) so the child never blocks on backpressure while we wait
    /// for its exit.
    static func drain(
        _ stream: DataChannel.ChildWrite.ParentRead,
        cap: Int
    ) async -> (data: Data, truncated: Bool) {
        var collected = Data()
        var truncated = false
        for await chunk in stream {
            for (index, line) in chunk.enumerated() {
                if index > 0, collected.count < cap {
                    collected.append(streamSeparator[0])
                }
                if collected.count < cap {
                    let space = cap - collected.count
                    if line.count > space {
                        collected.append(contentsOf: line[0..<space])
                        truncated = true
                    } else {
                        collected.append(contentsOf: line)
                    }
                } else if !truncated {
                    truncated = true
                }
            }
        }
        return (collected, truncated)
    }
}
