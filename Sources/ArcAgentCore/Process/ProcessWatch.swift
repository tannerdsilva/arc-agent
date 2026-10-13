import Foundation
import ServiceLifecycle

// MARK: - Process watching (plan B) + owned-process events (plan A)
//
// Plan A: processes the agent itself spawns emit `process:spawned` /
// `process:exited` HookBus events so hooks, jobs, and notifications can
// react to them (see `ProcessRegistry`).
//
// Plan B: `ProcessWatchService` polls the OS process table (`ps` on
// Darwin/Linux, explicit `-o` columns, `ww`), diffs snapshots, applies
// the scoping engine (allowlist + deny + identity), and emits
// `process:started` / `process:exited` / `process:threshold` for
// allowlisted processes only. Observe-only by default; control requires
// per-target `control: true` plus the agent-level approval gate.
//
// Security invariants (see docs/process-monitoring.md):
// - fail-closed: no targets configured => nothing is observed
// - pid reuse cannot mis-attribute: identity = (pid, started mark)
// - no shell: `ps` is argv-only, signal is `/bin/kill -s <sig> <pid>`
// - command lines are redacted before leaving the watcher

// MARK: - Config

/// One watch rule. Any specified field narrows the match (AND); a rule
/// with no fields matches nothing.
public struct ProcessTarget: Codable, Sendable, Equatable {
    /// Exact process name (`comm`, or the executable basename).
    public var name: String?
    /// Executable path prefix (e.g. "/usr/local/bin").
    public var pathPrefix: String?
    /// Regular expression over the full command line.
    public var cmdline: String?
    /// CPU % at/above which a `process:threshold` event fires.
    public var maxCpuPct: Double?
    /// Memory % at/above which a `process:threshold` event fires.
    public var maxMemPct: Double?
    /// Allow signal actions against this target (default false).
    public var control: Bool = false

    public init(
        name: String? = nil,
        pathPrefix: String? = nil,
        cmdline: String? = nil,
        maxCpuPct: Double? = nil,
        maxMemPct: Double? = nil,
        control: Bool = false
    ) {
        self.name = name
        self.pathPrefix = pathPrefix
        self.cmdline = cmdline
        self.maxCpuPct = maxCpuPct
        self.maxMemPct = maxMemPct
        self.control = control
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        self.pathPrefix = try c.decodeIfPresent(String.self, forKey: .pathPrefix)
        self.cmdline = try c.decodeIfPresent(String.self, forKey: .cmdline)
        self.maxCpuPct = try c.decodeIfPresent(Double.self, forKey: .maxCpuPct)
        self.maxMemPct = try c.decodeIfPresent(Double.self, forKey: .maxMemPct)
        self.control = try c.decodeIfPresent(Bool.self, forKey: .control) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case pathPrefix = "path_prefix"
        case cmdline
        case maxCpuPct = "max_cpu_pct"
        case maxMemPct = "max_mem_pct"
        case control
    }
}

/// `process_watch` configuration (`~/.arc/config.json` → `processWatch`).
public struct ProcessWatchConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var intervalSeconds: Double
    public var targets: [ProcessTarget]
    public var deny: [ProcessTarget]
    /// Bounded history of events kept for `process_watch status`.
    public var maxEvents: Int

    public init(
        enabled: Bool = false,
        intervalSeconds: Double = 5,
        targets: [ProcessTarget] = [],
        deny: [ProcessTarget] = [],
        maxEvents: Int = 200
    ) {
        self.enabled = enabled
        self.intervalSeconds = intervalSeconds
        self.targets = targets
        self.deny = deny
        self.maxEvents = maxEvents
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.intervalSeconds = try c.decodeIfPresent(Double.self, forKey: .intervalSeconds) ?? 5
        self.targets = try c.decodeIfPresent([ProcessTarget].self, forKey: .targets) ?? []
        self.deny = try c.decodeIfPresent([ProcessTarget].self, forKey: .deny) ?? []
        self.maxEvents = try c.decodeIfPresent(Int.self, forKey: .maxEvents) ?? 200
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, intervalSeconds = "interval_seconds", targets, deny, maxEvents = "max_events"
    }
}

// MARK: - Process model

/// One row of the OS process table with the identity needed to scope and
/// diff (pid + started mark defeats pid-reuse races).
public struct ProcessRecord: Sendable, Equatable, Identifiable {
    public let pid: Int32
    public let ppid: Int32
    public let state: String
    /// Decaying average (macOS `ps` semantics); treat as a trend, not a
    /// spike meter.
    public let cpuPercent: Double
    public let memPercent: Double
    /// 16-char truncated `comm` (macOS).
    public let comm: String
    /// Full command line (redacted before it leaves the watcher).
    public let command: String
    /// `lstart` (e.g. "Mon Sep 28 17:51:59 2026") — identity mark.
    public let startKey: String

    public var id: Int32 { pid }

    /// Executable path (first token of the command line).
    public var executable: String {
        command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? command
    }

    /// Executable basename, or `comm` when the command line is empty.
    public var processName: String {
        let base = (executable as NSString).lastPathComponent
        return base.isEmpty ? comm : base
    }

    public init(
        pid: Int32, ppid: Int32, state: String, cpuPercent: Double, memPercent: Double,
        comm: String, command: String, startKey: String
    ) {
        self.pid = pid
        self.ppid = ppid
        self.state = state
        self.cpuPercent = cpuPercent
        self.memPercent = memPercent
        self.comm = comm
        self.command = command
        self.startKey = startKey
    }
}

// MARK: - Collector

/// Executes `ps` with explicit columns and parses it — no shell, argv
/// only. Darwin and Linux both expose `-o ...= lstart= command=`; the
/// row shape is identical enough for one parser (`comm` is truncated to
/// 16/15 chars on Darwin/Linux respectively, which is fine — the full
/// path lives in `command`).
public enum ProcessWatchCollector {

    static let lineRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^\s*(\d+)\s+(\d+)\s+(\S+)\s+([0-9.]+)\s+([0-9.]+)\s+(\S+)\s+(.{24})\s*(.*)$"#
    )

    static func psPath() -> String {
        #if os(Linux)
        for candidate in ["/bin/ps", "/usr/bin/ps"] where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return "/bin/ps"
        #else
        return "/bin/ps"
        #endif
    }

    /// Take a full process snapshot (all users, not just own).
    public static func collect(timeout: TimeInterval = 20) async throws -> [ProcessRecord] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: psPath())
        proc.arguments = [
            "-axww",
            "-o", "pid=", "-o", "ppid=", "-o", "state=", "-o", "pcpu=",
            "-o", "pmem=", "-o", "comm=", "-o", "lstart=", "-o", "command=",
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProcessWatchError.collect("ps produced non-UTF8 output")
        }
        var out: [ProcessRecord] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let info = parse(line: String(line)) {
                out.append(info)
            }
        }
        return out
    }

    /// Parse one `ps -o` row. Tolerant: malformed rows are skipped.
    static func parse(line: String) -> ProcessRecord? {
        guard let regex = lineRegex,
              let match = regex.firstMatch(
                  in: line, range: NSRange(line.startIndex..., in: line)
              ) else { return nil }
        let m = { (i: Int) -> String in
            String(line[Range(match.range(at: i), in: line)!])
        }
        guard let pid = Int32(m(1)), let ppid = Int32(m(2)),
              let cpu = Double(m(4)), let mem = Double(m(5)) else { return nil }
        return ProcessRecord(
            pid: pid, ppid: ppid, state: m(3), cpuPercent: cpu, memPercent: mem,
            comm: m(6), command: m(8), startKey: m(7)
        )
    }
}

public enum ProcessWatchError: Error, CustomStringConvertible {
    case collect(String)
    case notAllowlisted(Int32)
    case controlNotPermitted(String)
    case invalidSignal(String)
    case signalFailed(Int32, String)

    public var description: String {
        switch self {
        case .collect(let m): return "process snapshot failed: \(m)"
        case .notAllowlisted(let pid): return "process \(pid) is not in the watch scope"
        case .controlNotPermitted(let name): return "control of '\(name)' is not permitted (target lacks control: true)"
        case .invalidSignal(let s): return "invalid signal '\(s)'"
        case .signalFailed(let pid, let m): return "signal to \(pid) failed: \(m)"
        }
    }
}

// MARK: - Scoping

/// Result of scoping one process against the watch config.
public enum ProcessScope: Sendable, Equatable {
    case denied
    case unlisted
    /// Allowlisted; carries whether control actions are permitted.
    case allowlisted(control: Bool)
}

public enum ProcessMatcher {

    /// The built-in deny set: things a watcher should never touch even if
    /// a target rule would match them.
    public static let builtInDeny: [ProcessTarget] = [
        ProcessTarget(name: "launchd"),
        ProcessTarget(name: "kernel_task"),
        ProcessTarget(name: "systemd"),
        ProcessTarget(name: "init"),
        ProcessTarget(name: "sshd"),
        ProcessTarget(name: "WindowServer"),
        ProcessTarget(name: "loginwindow"),
    ]

    /// Whole-table deny: pid 0/1 and the watcher/agent process tree.
    public static func hardDenied(_ info: ProcessRecord, agentPIDs: Set<Int32>) -> Bool {
        info.pid <= 1 || agentPIDs.contains(info.pid)
    }

    /// Does `info` match `target`? Every specified field must match
    /// (AND). A target with no identity field (name/path/cmdline) matches
    /// nothing — fail-closed, and identity-free threshold-only rules are
    /// not supported.
    public static func matches(_ info: ProcessRecord, _ target: ProcessTarget) -> Bool {
        guard target.name != nil || target.pathPrefix != nil || target.cmdline != nil else {
            return false
        }
        var hit = true
        if let name = target.name {
            hit = hit && (info.comm == name || info.processName == name)
        }
        if let prefix = target.pathPrefix {
            hit = hit && info.executable.hasPrefix(prefix)
        }
        if let pattern = target.cmdline {
            hit = hit && matchesRegex(pattern, in: info.command)
        }
        return hit
    }

    /// Scope one process: denied (hard + configured), allowlisted (with
    /// control), or unlisted (invisible to the watcher and tooling).
    public static func scope(
        _ info: ProcessRecord,
        config: ProcessWatchConfig,
        agentPIDs: Set<Int32> = []
    ) -> ProcessScope {
        if hardDenied(info, agentPIDs: agentPIDs) { return .denied }
        for rule in config.deny where matches(info, rule) { return .denied }
        for rule in ProcessMatcher.builtInDeny where matches(info, rule) { return .denied }
        for rule in config.targets where matches(info, rule) {
            return .allowlisted(control: rule.control)
        }
        return .unlisted
    }

    static func matchesRegex(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}

// MARK: - Events

public enum ProcessWatchKind: String, Sendable, Codable {
    case started
    case exited
    case threshold
}

public struct ProcessWatchEvent: Sendable, Equatable {
    public let kind: ProcessWatchKind
    public let pid: Int32
    public let name: String
    public let command: String
    public let cpuPercent: Double
    public let memPercent: Double
    public let at: Date

    public init(
        kind: ProcessWatchKind, pid: Int32, name: String, command: String,
        cpuPercent: Double, memPercent: Double, at: Date = Date()
    ) {
        self.kind = kind
        self.pid = pid
        self.name = name
        self.command = command
        self.cpuPercent = cpuPercent
        self.memPercent = memPercent
        self.at = at
    }

    public var hookEvent: String { "process:\(kind.rawValue)" }

    public var hookContext: [String: HookValue] {
        [
            "pid": .int(Int(pid)),
            "name": .string(name),
            "command": .string(command),
            "cpu_pct": .string(String(format: "%.1f", cpuPercent)),
            "mem_pct": .string(String(format: "%.1f", memPercent)),
            "state": .string("watch"),
            "host": .string(ProcessInfo.processInfo.hostName),
        ]
    }
}

/// Cheap redaction of command lines before they leave the watcher (same
/// spirit as the reference's terminal-output redaction).
public enum ProcessRedaction {
    static let secretPatterns: [(NSRegularExpression, String)] = [
        (pattern(#"(?i)([a-z0-9_]*token|[a-z0-9_]*key|password|passwd|secret|bearer)\s*[=:]\s*\S+"#), "$1=<redacted>"),
        (pattern(#"(?i)authorization:\s*(?:bearer\s+)?\S+"#), "authorization:<redacted>"),
        (pattern(#"sk-[A-Za-z0-9_-]{12,}"#), "sk-<redacted>"),
        (pattern(#"(?i)--password\s+\S+"#), "--password <redacted>"),
    ]

    static func pattern(_ s: String) -> NSRegularExpression {
        (try? NSRegularExpression(pattern: s)) ?? NSRegularExpression()
    }

    public static func redact(_ command: String) -> String {
        var text = command
        for (regex, template) in secretPatterns {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
        }
        return text
    }
}

// MARK: - Service

/// The single long-lived watcher (Second Law: one Service in the daemon
/// tree). Polls, diffs, scopes, emits through ``HookBus``, and answers
/// `process_watch` tool queries.
public actor ProcessWatchService: Service {

    public static let shared = ProcessWatchService()

    public var config: ProcessWatchConfig = ProcessWatchConfig()
    private var previous: [Int32: ProcessRecord] = [:]
    private var crossed: [String: Double] = [:]
    private var events: [ProcessWatchEvent] = []
    private(set) var lastPoll: Date?
    private(set) var pollCount: Int = 0

    /// Processes this daemon/agent owns (never emit or control them as
    /// "watched" — they're already covered by `process:spawned`). Set by
    /// the daemon at boot; the watcher adds its own children lazily.
    public var agentPIDs: Set<Int32> = []

    public func setAgentPIDs(_ pids: Set<Int32>) {
        agentPIDs = pids
    }

    public init(config: ProcessWatchConfig = ProcessWatchConfig()) {
        self.config = config
    }

    public func configure(_ newConfig: ProcessWatchConfig) {
        config = newConfig
        events = []
        crossed = [:]
        previous = [:]
    }

    // MARK: Service

    public func run() async throws {
        try await runUntilShutdown { [self] in
            while !Task.isCancelled {
                await pollOnce()
                try? await Task.sleep(for: .seconds(config.intervalSeconds))
            }
        }
    }

    // MARK: Polling

    /// One poll: collect, diff against the previous snapshot, emit
    /// scoped events. Public so tests can drive deterministic polls.
    public func pollOnce() async {
        guard config.enabled, !config.targets.isEmpty else {
            lastPoll = Date()
            pollCount += 1
            return
        }
        guard let current = try? await ProcessWatchCollector.collect() else {
            lastPoll = Date()
            pollCount += 1
            return
        }
        await pollOnce(with: current)
    }

    /// Diff `current` against the previous snapshot and emit. Public so
    /// tests inject deterministic snapshots instead of live `ps`.
    public func pollOnce(with current: [ProcessRecord]) async {
        lastPoll = Date()
        pollCount += 1
        let events = eventsAfter(previous: previous, current: current)
        previous = Dictionary(uniqueKeysWithValues: current.map { ($0.pid, $0) })
        for (kind, info) in events {
            await emit(kind, info)
        }
    }

    /// Pure diff: started/exited (identity-aware) + threshold edges.
    /// Mutates `crossed` (hysteresis) and returns what to emit.
    private func eventsAfter(previous: [Int32: ProcessRecord], current: [ProcessRecord]) -> [(ProcessWatchKind, ProcessRecord)] {
        var out: [(ProcessWatchKind, ProcessRecord)] = []
        let currentByPid = Dictionary(uniqueKeysWithValues: current.map { ($0.pid, $0) })

        for info in current {
            guard case .allowlisted = ProcessMatcher.scope(info, config: config, agentPIDs: agentPIDs) else {
                continue
            }
            if let old = previous[info.pid] {
                if old.startKey == info.startKey {
                    // Same process: threshold edges only.
                    out.append(contentsOf: thresholdEdges(pid: info.pid, info: info))
                } else {
                    // PID reuse: exit the old identity, start the new.
                    out.append((.exited, old))
                    out.append((.started, info))
                }
                continue
            }
            out.append((.started, info))
        }
        for (pid, old) in previous where currentByPid[pid] == nil {
            if case .allowlisted = ProcessMatcher.scope(old, config: config, agentPIDs: agentPIDs) {
                out.append((.exited, old))
            }
        }
        return out
    }

    /// Threshold crossings with 10% hysteresis so a process hovering at
    /// the line does not re-emit every poll.
    private func thresholdEdges(pid: Int32, info: ProcessRecord) -> [(ProcessWatchKind, ProcessRecord)] {
        var out: [(ProcessWatchKind, ProcessRecord)] = []
        let matching = config.targets.filter { ProcessMatcher.matches(info, $0) }
        if let cap = matching.compactMap({ $0.maxCpuPct }).min(),
           info.cpuPercent >= cap {
            let key = "\(pid):cpu"
            if (crossed[key] ?? 0) < cap {
                crossed[key] = info.cpuPercent
                out.append((.threshold, info))
            }
        } else if info.cpuPercent < (crossed["\(pid):cpu"] ?? 0) * 0.9 {
            crossed["\(pid):cpu"] = nil
        }
        if let cap = matching.compactMap({ $0.maxMemPct }).min(),
           info.memPercent >= cap {
            let key = "\(pid):mem"
            if (crossed[key] ?? 0) < cap {
                crossed[key] = info.memPercent
                out.append((.threshold, info))
            }
        } else if info.memPercent < (crossed["\(pid):mem"] ?? 0) * 0.9 {
            crossed["\(pid):mem"] = nil
        }
        return out
    }

    private func emit(_ kind: ProcessWatchKind, _ info: ProcessRecord) async {
        let redacted = ProcessRedaction.redact(info.command)
        let event = ProcessWatchEvent(
            kind: kind, pid: info.pid, name: info.processName,
            command: redacted, cpuPercent: info.cpuPercent, memPercent: info.memPercent
        )
        events.append(event)
        if events.count > config.maxEvents {
            events.removeFirst(events.count - config.maxEvents)
        }
        await HookBus.shared.emit(event.hookEvent, event.hookContext)
    }

    // MARK: Tool surface

    /// Scoped snapshot for `process_watch list` (allowlisted only).
    public func scopedSnapshot() async -> [ProcessRecord] {
        guard let current = try? await ProcessWatchCollector.collect() else { return [] }
        return current.filter {
            if case .allowlisted = ProcessMatcher.scope($0, config: config, agentPIDs: agentPIDs) { return true }
            return false
        }
    }

    public func recentEvents() -> [ProcessWatchEvent] {
        events
    }

    /// Inspect one process; nil when out of scope (fail-closed).
    public func inspect(pid: Int32) async -> (info: ProcessRecord, scope: ProcessScope)? {
        guard let current = try? await ProcessWatchCollector.collect(),
              let info = current.first(where: { $0.pid == pid }) else { return nil }
        let scope = ProcessMatcher.scope(info, config: config, agentPIDs: agentPIDs)
        guard case .allowlisted = scope else { return nil }
        return (info, scope)
    }

    /// Control action: only for allowlisted targets with `control: true`.
    /// `/bin/kill` via argv (no shell), signal names allowlisted. The
    /// agent-level approval gate runs before this is reached.
    public func signal(pid: Int32, signalName: String) async throws -> String {
        guard ["TERM", "INT", "HUP", "KILL", "STOP", "CONT", "USR1", "USR2"].contains(signalName) else {
            throw ProcessWatchError.invalidSignal(signalName)
        }
        guard let current = try? await ProcessWatchCollector.collect(),
              let info = current.first(where: { $0.pid == pid }) else {
            throw ProcessWatchError.signalFailed(pid, "no such process")
        }
        switch ProcessMatcher.scope(info, config: config, agentPIDs: agentPIDs) {
        case .denied, .unlisted:
            throw ProcessWatchError.notAllowlisted(pid)
        case .allowlisted(let control):
            guard control else {
                throw ProcessWatchError.controlNotPermitted(info.processName)
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/kill")
        process.arguments = ["-s", signalName, String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw ProcessWatchError.signalFailed(pid, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if process.terminationStatus != 0 {
            throw ProcessWatchError.signalFailed(pid, message.isEmpty ? "exit \(process.terminationStatus)" : message)
        }
        return "sent \(signalName) to \(pid) (\(info.processName))"
    }

    // MARK: Config view

    public func targetsSummary() -> [String] {
        config.targets.map { target in
            var parts: [String] = []
            if let n = target.name { parts.append("name=\(n)") }
            if let p = target.pathPrefix { parts.append("path=\(p)") }
            if let c = target.cmdline { parts.append("cmdline=\(c)") }
            if let cpu = target.maxCpuPct { parts.append("cpu>\(cpu)") }
            if let mem = target.maxMemPct { parts.append("mem>\(mem)") }
            parts.append(target.control ? "control" : "observe-only")
            return parts.joined(separator: " ")
        }
    }
}
