import Foundation

/// arc-parity background process registry for the `terminal` tool.
///
/// reference' `terminal(background=true)` returns a stable `session_id` that the
/// agent manages with `process(action: poll|log|wait|kill)`. This actor is the
/// arc-agent equivalent: it owns the child sessions, captures their output to a
/// per-session log file, tracks exit state, and serves the same collect surface.
///
/// ## Rationale (vascular hardening)
/// Long runs (`swift test` on a big suite, builds, servers) used to burn the
/// whole 180–300 s foreground budget and stall the turn loop. With background
/// + collect the agent starts the run, keeps working (editing, reading, other
/// calls), and only collects when it needs the result — exactly the reference
/// pattern.
///
/// ## Concurrency
/// Each session is a ``SubprocessSession``: a SwiftSlash child with `.own`
/// process-group placement, byte channels, and one structured task that owns the
/// reap. Nothing blocks a thread and nothing is signalled by hand.
///
/// This used to be the codebase's documented `Foundation.Process` exception.
/// `Process` has no placement knob, so the shell joined **arc's own** process
/// group: `kill` signalled the shell's pid while whatever the shell had started
/// kept running, and the group arc could never address was the one it needed.
/// The `.own` placement is what makes ``kill(id:)`` one signal that reaches the
/// tree. Output is appended to a temp file rather than piped, so capture can
/// never deadlock on a full pipe buffer and reads stay demand-driven.
public actor ProcessRegistry {

    public static let shared = ProcessRegistry()

    /// Cap on how much of a session log `log`/`poll` will surface.
    static let outputCap = 100_000

    private final class Entry {
        let id: String
        let command: String
        let workdir: String?
        let session: SubprocessSession
        /// The pid the kernel assigned, when one was observable. A child that exits
        /// faster than the launch poll publishes no pid, and the session still works.
        let pid: Int32?
        let logURL: URL
        let outputHandle: FileHandle
        let startedAt = Date()
        private(set) var exited = false
        private(set) var exitCode: Int? = nil
        private(set) var completionReason = "exited"
        /// arc ended this session, so the exit status is a consequence not a cause.
        private(set) var requestedKill = false

        func requestKill() { requestedKill = true }

        init(id: String, command: String, workdir: String?, session: SubprocessSession,
             pid: Int32?, logURL: URL, outputHandle: FileHandle) {
            self.id = id
            self.command = command
            self.workdir = workdir
            self.session = session
            self.pid = pid
            self.logURL = logURL
            self.outputHandle = outputHandle
        }

        func markExited(code: Int, reason: String) {
            exited = true
            exitCode = code
            completionReason = reason
            try? outputHandle.close()
        }
    }

    private var entries: [String: Entry] = [:]

    // MARK: - Start

    /// Start `command` in the background, capturing combined stdout/stderr to a
    /// temp log. Returns the arc-style `session_id` for ``poll``/``log``/``wait``/
    /// ``kill``.
    @discardableResult
    public func start(command: String, workdir: String? = nil) async throws -> String {
        let id = UUID().uuidString.lowercased()
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-proc-\(id).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: logURL)

        // The shell runs through the same session type as every other long-lived
        // child arc owns — one spawn path, `.own` placement, byte channels.
        let session = SubprocessSession(
            executable: "/bin/bash",
            arguments: ["-c", command],
            workingDirectory: workdir)
        let pid: Int32?
        do {
            pid = try await session.start()
        } catch {
            try? outputHandle.close()
            throw error
        }

        let entry = Entry(
            id: id, command: command, workdir: workdir,
            session: session, pid: pid, logURL: logURL, outputHandle: outputHandle)
        entries[id] = entry

        // Plan A: owned-process lifecycle events for hooks/jobs/notifications.
        let spawnedContext: [String: HookValue] = [
            "session_id": .string(id),
            "command": .string(command),
            // 0 when the child exited before its pid was observable
            "pid": .int(Int(pid ?? 0)),
            "workdir": .string(workdir ?? ""),
            "host": .string(ProcessInfo.processInfo.hostName),
        ]
        Task { await HookBus.shared.emit("process:spawned", spawnedContext) }

        // One structured task per session: drain both byte channels into the log,
        // then record the exit state. The group's implicit await at scope exit is
        // what guarantees the log is complete before `exited` becomes observable.
        Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await bytes in session.stdout {
                        await self?.append(bytes, id: id)
                    }
                }
                group.addTask {
                    for await bytes in session.stderr {
                        await self?.append(bytes, id: id)
                    }
                }
            }
            // The reap is the authority for both values: await it rather than
            // reading state the drain may have outraced (a child can close both
            // channels before it is reaped).
            let exit = await session.waitForExit() ?? -1
            let reason = await session.exitStatus()?.reason ?? "exited"
            await self?.markExited(id: id, code: Int(exit), reason: reason)
        }
        return id
    }

    // MARK: - Collect surface (reference `process` tool parity)

    public struct Snapshot: Sendable {
        public let sessionID: String
        public let command: String
        public let status: String      // running | exited
        public let exitCode: Int?
        public let completionReason: String
        public let output: String
    }

    /// One-line summaries for `process(action: "list")`.
    /// A snapshot row for the `process list` tool. Concrete values (not
    /// `[String: Any]`) so it can cross actor/task boundaries as `Sendable`.
    public struct ProcessSummary: Sendable {
        public let sessionID: String
        public let command: String
        public let status: String
        public let exitCode: Int?
        public let pid: Int32?

        public init(sessionID: String, command: String, status: String, exitCode: Int?, pid: Int32? = nil) {
            self.sessionID = sessionID
            self.command = command
            self.status = status
            self.exitCode = exitCode
            self.pid = pid
        }
    }

    public func summaries() -> [ProcessSummary] {
        entries.values
            .sorted { $0.startedAt < $1.startedAt }
            .map { entry in
                ProcessSummary(
                    sessionID: entry.id,
                    command: entry.command,
                    status: entry.exited ? "exited" : "running",
                    exitCode: entry.exitCode,
                    pid: entry.pid
                )
            }
    }

    /// Snapshot for `poll`/`wait`: status + exit state + the session output
    /// (bounded to ``outputCap`` — full history via `log`).
    public func snapshot(id: String, tailLimit: Int = 2_000) -> Snapshot? {
        guard let entry = entries[id] else { return nil }
        let raw = readLog(id: id) ?? ""
        let tail = String(raw.suffix(tailLimit))
        return Snapshot(
            sessionID: entry.id,
            command: entry.command,
            status: entry.exited ? "exited" : "running",
            exitCode: entry.exitCode,
            completionReason: entry.completionReason,
            output: tail
        )
    }

    /// Convenience alias matching the `process(action: "poll")` surface.
    public func poll(id: String) -> Snapshot? {
        snapshot(id: id)
    }

    /// Full output for `log` (offset/limit semantics, arc parity).
    public func log(id: String, offset: Int = 0, limit: Int = 200) -> Snapshot? {
        guard let entry = entries[id] else { return nil }
        let raw = readLog(id: id) ?? ""
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        let start = min(max(offset, 0), lines.count)
        let slice = lines[start..<min(lines.count, start + max(limit, 0))]
        return Snapshot(
            sessionID: entry.id,
            command: entry.command,
            status: entry.exited ? "exited" : "running",
            exitCode: entry.exitCode,
            completionReason: entry.completionReason,
            output: slice.joined(separator: "\n")
        )
    }

    /// Block until the session exits or `timeout` seconds elapse.
    public func wait(id: String, timeout: Int) async -> Snapshot? {
        guard let entry = entries[id] else { return nil }
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while !entry.exited && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000) // 200 ms
        }
        return snapshot(id: id)
    }

    /// Terminate a session: SIGTERM to its process group, SIGKILL if it holds on
    /// past the grace, then the reaper records `killed`. No-op for exited
    /// sessions. Waits (bounded, 3 s) for the reaper so the returned snapshot is
    /// settled.
    public func kill(id: String) async -> Snapshot? {
        guard let entry = entries[id] else { return nil }
        if !entry.exited {
            // One signal, aimed at the GROUP. The session asked for `.own`, so the
            // shell leads its own group and this reaches the shell and everything it
            // started — including `swift test` and the compilers beneath it. The old
            // path spawned a `/bin/bash -c "pkill -P <pid>; sleep 0.2; kill <pid>"`
            // helper *because* a pid-only signal could not reach the tree — the
            // placement removes the need for the helper entirely.
            entry.requestKill()
            await entry.session.shutdown(grace: .seconds(2))
        }
        // Bounded settle: the session's reaper records exit state asynchronously.
        let deadline = Date().addingTimeInterval(3)
        while !entry.exited && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms
        }
        return snapshot(id: id)
    }

    // MARK: - Internals

    /// Append child output to the session log. Called from the drain tasks, but
    /// always executes inside the actor, so the two streams can never interleave a
    /// partial write and the `FileHandle` never leaves this isolation domain.
    private func append(_ bytes: [UInt8], id: String) {
        guard let entry = entries[id], !bytes.isEmpty else { return }
        try? entry.outputHandle.write(contentsOf: bytes)
    }

    private func markExited(id: String, code: Int, reason: String) {
        guard let entry = entries[id], !entry.exited else { return }
        // arc asked for the kill: whatever the exit status says (a shell reports
        // 143 rather than dying by signal), the session ended because arc ended it,
        // and that is what the `process` surface reports.
        entry.markExited(code: code, reason: entry.requestedKill ? "killed" : reason)
        // Plan A: exit lifecycle event (fires exactly once, in the reaper).
        let context: [String: HookValue] = [
            "session_id": .string(id),
            "command": .string(entry.command),
            "exit_code": .int(code),
            "reason": .string(reason),
            "workdir": .string(entry.workdir ?? ""),
            "host": .string(ProcessInfo.processInfo.hostName),
        ]
        Task { await HookBus.shared.emit("process:exited", context) }
    }

    private func readLog(id: String) -> String? {
        guard let entry = entries[id] else { return nil }
        if let data = try? Data(contentsOf: entry.logURL),
           data.count > Self.outputCap {
            // Keep reads bounded: last outputCap bytes.
            return String(data: data.suffix(Self.outputCap), encoding: .utf8)
        }
        return try? String(contentsOf: entry.logURL, encoding: .utf8)
    }
}