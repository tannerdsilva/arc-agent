import Foundation
import SwiftSlash
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - SubprocessSession (SwiftSlash-backed long-lived child)

/// A long-lived child process owned by one actor, with byte channels.
///
/// ``SubprocessRunner`` is arc's *run-to-completion* entry point; this is the
/// *session* entry point. Both spawn through SwiftSlash with `.own` process
/// group placement, so a single signal at teardown reaches the child's whole
/// tree and nothing outside it — the contract in `docs/process-placement.md`.
///
/// Three call sites share this shape: the cua-driver MCP peer, a web-UI sidecar
/// plugin, and the `terminal(background: true)` shell. Each one previously built
/// its own `Foundation.Process` plus three `Pipe`s plus a `readabilityHandler`
/// reader. That construction has **no placement knob at all**, so every one of
/// those children joined *arc's own* process group: a per-session teardown could
/// not reach it, and a kill reached a pid instead of a tree. Routing all three
/// through one session type is what removes the Foundation spawn from the
/// codebase rather than hiding it behind a comment.
///
/// Framing is deliberately *not* built in. ``stdout``/``stderr`` yield raw byte
/// chunks; a caller that wants lines feeds them through ``LineAccumulator``. A
/// separator chosen here would silently strip newlines out of a background
/// shell's log, which is the one thing a log must keep.
///
/// Lifecycle: `start()` → (writes / reads) → `shutdown()`. The actor owns the
/// single task that reaps (`run()` suspends for the child's lifetime and returns
/// its exit status), so no thread is blocked and no exit status is ever missed.
public actor SubprocessSession {

    /// Failures a session can report as a value.
    public enum SessionError: Error, Sendable, CustomStringConvertible {
        case notExecutable(String)
        case alreadyStarted
        case notStarted
        case launchFailed(String)
        case channelClosed

        public var description: String {
            switch self {
            case .notExecutable(let path):
                return "not an executable absolute path: \(path)"
            case .alreadyStarted:
                return "session already started"
            case .notStarted:
                return "session has not been started"
            case .launchFailed(let path):
                return "failed to launch: \(path)"
            case .channelClosed:
                return "stdin channel is closed"
            }
        }
    }

    /// A session's exit, in the two shapes a caller cares about.
    public struct ExitStatus: Sendable {
        /// `128 + signal` for a signalled child, per shell convention.
        public let code: Int32
        /// `"exited"` or `"killed"`.
        public let reason: String
    }

    // MARK: Configuration

    private let executable: String
    private let arguments: [String]
    private let workingDirectory: String?
    private let environment: [String: String]?

    // MARK: Live state

    private var child: ChildProcess?
    private var runTask: Task<ChildProcess.Exit?, Never>?
    private var pumps: [Task<Void, Never>] = []
    private var reaped: ChildProcess.Exit?
    private var launchedPID: Int32?

    /// Raw stdout bytes. Ends when the child's stdout closes.
    public nonisolated let stdout: AsyncStream<[UInt8]>
    /// Raw stderr bytes. Ends when the child's stderr closes.
    public nonisolated let stderr: AsyncStream<[UInt8]>
    private nonisolated let stdoutSink: AsyncStream<[UInt8]>.Continuation
    private nonisolated let stderrSink: AsyncStream<[UInt8]>.Continuation

    /// - Parameters:
    ///   - executable: An **absolute** path. A relative name or a bare command is
    ///     refused by ``start()`` rather than handed to the spawn machinery, where
    ///     a path that cannot be executed creates no child and leaves the launch
    ///     waiting on a continuation nothing resumes (a hang with no diagnostic).
    ///   - environment: The child's *whole* environment. `nil` inherits arc's.
    public init(
        executable: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        let (out, outSink) = AsyncStream<[UInt8]>.makeStream(bufferingPolicy: .unbounded)
        let (err, errSink) = AsyncStream<[UInt8]>.makeStream(bufferingPolicy: .unbounded)
        self.stdout = out
        self.stderr = err
        self.stdoutSink = outSink
        self.stderrSink = errSink
    }

    // MARK: - Launch

    /// Spawn the child and return its pid, when one is observable.
    ///
    /// `ChildProcess.run()` publishes `.running(pid)` and then suspends for the
    /// child's whole lifetime, so there is no separate "launched" completion to
    /// await — but the published state *is* the answer. `.reaped` is ambiguous
    /// (the exec may have failed, or the child may simply have finished before
    /// this poll saw it), so it is treated as "already done": the session is
    /// usable and the pid is simply nil. A launch that never resolves at all is
    /// the one case that is genuinely broken, and that throws.
    @discardableResult
    public func start() async throws -> Int32? {
        guard child == nil else { throw SessionError.alreadyStarted }
        guard executable.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: executable)
        else { throw SessionError.notExecutable(executable) }

        var command = Command(absolutePath: Path(executable), arguments: arguments)
        if let environment {
            command.environment = environment
        } else {
            command.inheritCurrentEnvironment()
        }
        if let workingDirectory {
            command.workingDirectory = Path(workingDirectory)
        }

        // `.own`, for the same reason as `SubprocessRunner`: arc owns the process
        // group of everything it spawns, so one teardown signal reaches the child
        // and its tree. `separator: []` disables the line parser, so each segment
        // is exactly the bytes that were read — no newline is consumed.
        let session = ChildProcess(command, processGroup: .own, dataChannels: [
            STDOUT_FILENO: .write(.toParentProcess(stream: .init(), separator: [])),
            STDERR_FILENO: .write(.toParentProcess(stream: .init(), separator: [])),
            STDIN_FILENO: .read(.fromParentProcess(stream: .init())),
        ])
        child = session

        // Pumps run as their own tasks and are created before the launch so not
        // one byte can be lost between exec and the first read. Each ends when its
        // channel closes, which happens when the child's descriptor is closed.
        let outSink = stdoutSink
        let errSink = stderrSink
        pumps = [
            Task {
                for await chunk in session.stdout {
                    for slice in chunk { outSink.yield(slice) }
                }
                outSink.finish()
            },
            Task {
                for await chunk in session.stderr {
                    for slice in chunk { errSink.yield(slice) }
                }
                errSink.finish()
            },
        ]

        // One task owns the reap. `run()` returns the exit status after the child
        // has been waited for, so recording it here is the only place exit state
        // becomes observable — there is no second reaper and nothing to race.
        runTask = Task { [weak self] in
            let exit = try? await session.run(cancellationSignal: SIGTERM)
            await self?.record(exit)
            return exit
        }

        return try await awaitLaunch()
    }

    private func awaitLaunch() async throws -> Int32? {
        for _ in 0..<600 {
            guard let state = await child?.state else { return launchedPID }
            switch state {
            case .running(let pid):
                launchedPID = pid
                return pid
            case .reaped:
                // launched and already finished — a child can outrun this poll, and
                // reporting that as a failed launch would be a lie about a session
                // that worked
                return launchedPID
            case .initialized, .launching:
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        throw SessionError.launchFailed(executable)
    }

    // MARK: - I/O

    /// Write bytes to the child's stdin, returning once they are flushed.
    public func write(_ bytes: [UInt8]) async throws {
        guard let child else { throw SessionError.notStarted }
        guard reaped == nil else { throw SessionError.channelClosed }
        do {
            try await child.stdin.write(bytes)
        } catch {
            throw SessionError.channelClosed
        }
    }

    /// Signal EOF on the child's stdin without otherwise ending the session.
    public func closeStdin() {
        child?.stdin.closeDataChannel()
    }

    // MARK: - State

    public func pid() -> Int32? { launchedPID }

    public func isRunning() -> Bool { child != nil && reaped == nil }

    /// The recorded exit, or nil while the child is alive.
    public func exitStatus() -> ExitStatus? {
        guard let reaped else { return nil }
        switch reaped {
        case .code(let code):
            return ExitStatus(code: code, reason: "exited")
        case .signal(let signal):
            return ExitStatus(code: 128 + signal, reason: "killed")
        }
    }

    /// Await the reap and return the exit code (nil only if the launch failed).
    @discardableResult
    public func waitForExit() async -> Int32? {
        _ = await runTask?.value
        return exitStatus()?.code
    }

    // MARK: - Teardown

    /// Signal the child's group with `SIGTERM`, waiting `grace` before escalating
    /// to `SIGKILL`, then await the reap. Idempotent.
    ///
    /// The signal goes to the **group**, not the pid: the child asked for `.own`,
    /// so it leads its group and this reaches everything it started. That is the
    /// reach the Foundation path never had — it signalled one pid and left
    /// grandchildren running.
    public func terminate(grace: Duration = .seconds(2)) async {
        guard let child else { return }
        if reaped == nil {
            try? await child.signal(SIGTERM, to: .processGroup)
            let deadline = ContinuousClock.now + grace
            while reaped == nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            if reaped == nil {
                try? await child.signal(SIGKILL, to: .processGroup)
            }
        }
        _ = await runTask?.value
        for pump in pumps { await pump.value }
        pumps = []
    }

    /// Close stdin (a cooperative peer exits on EOF) and then ``terminate(grace:)``.
    public func shutdown(grace: Duration = .seconds(2)) async {
        closeStdin()
        await terminate(grace: grace)
    }

    // MARK: - Internals

    private func record(_ exit: ChildProcess.Exit?) {
        reaped = exit ?? .signal(SIGKILL)
    }
}