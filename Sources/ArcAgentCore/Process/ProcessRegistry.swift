import Foundation

/// arc-parity background process registry for the `terminal` tool.
///
/// reference' `terminal(background=true)` returns a stable `session_id` that the
/// agent manages with `process(action: poll|log|wait|kill)`. This actor is the
/// arc-agent equivalent: it owns detached `Process` instances, captures their
/// output to a per-session log file, tracks exit state, and serves the same
/// collect surface.
///
/// ## Rationale (vascular hardening)
/// Long runs (`swift test` on a big suite, builds, servers) used to burn the
/// whole 180–300 s foreground budget and stall the turn loop. With background
/// + collect the agent starts the run, keeps working (editing, reading, other
/// calls), and only collects when it needs the result — exactly the reference
/// pattern.
///
/// ## Concurrency
/// Foundation `Process` is the documented background exception in this
/// codebase (SwiftSlash has no detached-launch API; see `TerminalTool`).
/// Each session gets one structured `Task` that reaps via `waitUntilExit()`
/// and records exit state — no ad-hoc daemon threads. Output goes to a temp
/// file rather than pipes, so capture can never deadlock on a full pipe
/// buffer and reads are demand-driven.
public actor ProcessRegistry {

    public static let shared = ProcessRegistry()

    /// Cap on how much of a session log `log`/`poll` will surface.
    static let outputCap = 100_000

    private final class Entry {
        let id: String
        let command: String
        let workdir: String?
        let process: Process
        let logURL: URL
        let outputHandle: FileHandle
        let startedAt = Date()
        private(set) var exited = false
        private(set) var exitCode: Int? = nil
        private(set) var completionReason = "exited"

        init(id: String, command: String, workdir: String?, process: Process,
             logURL: URL, outputHandle: FileHandle) {
            self.id = id
            self.command = command
            self.workdir = workdir
            self.process = process
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

    /// Start `command` detached, capturing combined stdout/stderr to a temp
    /// log. Returns the arc-style `session_id` for ``poll``/``log``/``wait``/
    /// ``kill``.
    @discardableResult
    public func start(command: String, workdir: String? = nil) throws -> String {
        let id = UUID().uuidString.lowercased()
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-proc-\(id).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: logURL)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", command]
        if let workdir {
            proc.currentDirectoryURL = URL(fileURLWithPath: workdir)
        }
        proc.standardOutput = outputHandle
        proc.standardError = outputHandle

        let entry = Entry(
            id: id, command: command, workdir: workdir,
            process: proc, logURL: logURL, outputHandle: outputHandle)
        entries[id] = entry

        try proc.run()

        // Reap + record exit state (one structured task per session).
        Task { [weak self] in
            proc.waitUntilExit()
            let code = Int(proc.terminationStatus)
            let reason = proc.terminationReason == .uncaughtSignal ? "killed" : "exited"
            await self?.markExited(id: id, code: code, reason: reason)
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
    public func summaries() -> [[String: Any]] {
        entries.values
            .sorted { $0.startedAt < $1.startedAt }
            .map { entry in
                [
                    "session_id": entry.id,
                    "command": entry.command,
                    "status": entry.exited ? "exited" : "running",
                    "exit_code": entry.exitCode as Any,
                ]
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

    /// Terminate a session (SIGTERM to the shell's children, then the shell;
    /// the reaper task records `killed`). No-op for exited sessions. Waits
    /// (bounded, 3 s) for the reaper so the returned snapshot is settled.
    public func kill(id: String) async -> Snapshot? {
        guard let entry = entries[id] else { return nil }
        if !entry.exited {
            let pid = entry.process.processIdentifier
            // SIGTERM the shell's direct children first (a bare SIGTERM to
            // bash would orphan `swift test` etc. in this same process group),
            // then the shell itself. /bin/kill spawn is the same documented
            // Foundation-Process exception as everything else here.
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/bash")
            helper.arguments = [
                "-c",
                "pkill -TERM -P \(pid) 2>/dev/null; sleep 0.2; kill -TERM \(pid) 2>/dev/null",
            ]
            try? helper.run()
            helper.waitUntilExit()
        }
        // Bounded settle: the actor reaper records exit state asynchronously.
        let deadline = Date().addingTimeInterval(3)
        while !entry.exited && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms
        }
        return snapshot(id: id)
    }

    // MARK: - Internals

    private func markExited(id: String, code: Int, reason: String) {
        guard let entry = entries[id] else { return }
        entry.markExited(code: code, reason: reason)
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
