import Foundation

/// The `process_watch` tool: observe and (rarely) control machine
/// processes through the scoped watcher.
///
/// Fail-closed by design: with no `processWatch.targets` configured,
/// `list` returns nothing and `inspect`/`signal` refuse — the watcher
/// never surfaces or touches a process that was not explicitly
/// allowlisted (security invariants in `docs/process-monitoring.md`).
///
/// Actions:
/// - `list` — allowlisted processes (pid, name, state, cpu, mem, redacted command).
/// - `inspect` — one pid: identity, stats, scope, control permission.
/// - `signal` — send TERM/INT/HUP/KILL/STOP/CONT/USR1/USR2 to an
///   allowlisted target with `control: true` (approval-gated at the
///   agent layer; observe-only otherwise).
/// - `targets` — the configured watch rules.
/// - `status` — watcher state + recent events.
public enum ProcessWatchTool {

    static let allowedActions = ["list", "inspect", "signal", "targets", "status"]

    public static let entry = ToolEntry(
        name: "process_watch",
        toolset: "terminal",
        description: "Inspect and react to the machine's processes through the scoped "
            + "process watcher: list (allowlisted only), inspect <pid>, signal <pid> "
            + "(requires control: true on the matching target — approval-gated), "
            + "targets (configured watch rules), status (watcher state + recent events). "
            + "Fail-closed: with no processWatch targets configured, nothing is listed "
            + "and no process can be signaled.",
        schema: .object(
            description: "Scoped process observation/control",
            properties: [
                "action": .enum(description: "What to do", values: Self.allowedActions),
                "pid": .integer(description: "Process id (inspect/signal)", default: 0),
                "signal": .string(
                    description: "Signal name for signal (TERM|INT|HUP|KILL|STOP|CONT|USR1|USR2)",
                    default: "TERM"
                ),
            ],
            required: ["action"]
        ),
        handler: { args in
            try await Self.handle(args)
        },
        emoji: "🩺"
    )

    static func handle(_ args: [String: Any]) async throws -> String {
        let action = (args["action"] as? String) ?? ""
        let watcher = ProcessWatchService.shared

        switch action {
        case "list":
            let info = await watcher.scopedSnapshot()
            let config = await watcher.config
            return try json([
                "processes": info.map { p in
                    var row = record(p)
                    row["control"] = controlPermitted(p, config: config)
                    return row
                },
                "note": "allowlisted processes only (processWatch.targets)",
            ] as [String: Any])

        case "inspect":
            guard let raw = args["pid"] as? Int, let pid = Int32(exactly: raw), pid > 0 else {
                return try json(["error": "pid is required for inspect"])
            }
            guard let found = await watcher.inspect(pid: pid) else {
                return try json(["error": "pid \(pid) is not in the watch scope (fail-closed)"])
            }
            var row = record(found.info)
            if case .allowlisted(let control) = found.scope {
                row["control"] = control
            }
            return try json(["process": row])

        case "signal":
            guard let raw = args["pid"] as? Int, let pid = Int32(exactly: raw), pid > 0 else {
                return try json(["error": "pid is required for signal"])
            }
            let signalName = ((args["signal"] as? String) ?? "TERM").uppercased()
            do {
                let message = try await watcher.signal(pid: pid, signalName: signalName)
                return try json(["result": message])
            } catch {
                return try json(["error": "\(error)"])
            }

        case "targets":
            let summary = await watcher.targetsSummary()
            return try json([
                "enabled": await watcher.config.enabled,
                "interval_seconds": await watcher.config.intervalSeconds,
                "targets": summary,
                "note": summary.isEmpty
                    ? "no targets: watcher is fail-closed and observes nothing"
                    : "observe-only unless a target declares control: true",
            ] as [String: Any])

        case "status":
            let events = await watcher.recentEvents()
            return try json([
                "enabled": await watcher.config.enabled,
                "interval_seconds": await watcher.config.intervalSeconds,
                "targets_configured": (await watcher.config.targets).count,
                "last_poll": await watcher.lastPoll.map { ISO8601DateFormatter().string(from: $0) }
                    ?? "never",
                "polls": await watcher.pollCount,
                "recent_events": events.suffix(20).map { event in
                    [
                        "kind": event.kind.rawValue,
                        "pid": Int(event.pid),
                        "name": event.name,
                        "command": event.command,
                        "cpu_pct": String(format: "%.1f", event.cpuPercent),
                        "mem_pct": String(format: "%.1f", event.memPercent),
                        "at": ISO8601DateFormatter().string(from: event.at),
                    ] as [String: Any]
                },
            ] as [String: Any])

        default:
            return try json([
                "error": "Unknown process_watch action: \(action). Use: \(Self.allowedActions.joined(separator: ", "))",
            ])
        }
    }

    // MARK: - Shape

    private static func controlPermitted(_ info: ProcessRecord, config: ProcessWatchConfig) -> Bool {
        if case .allowlisted(let control) = ProcessMatcher.scope(info, config: config) {
            return control
        }
        return false
    }

    private static func record(_ info: ProcessRecord) -> [String: Any] {
        [
            "pid": Int(info.pid),
            "ppid": Int(info.ppid),
            "name": info.processName,
            "state": info.state,
            "cpu_pct": info.cpuPercent,
            "mem_pct": info.memPercent,
            "command": ProcessRedaction.redact(info.command),
        ]
    }

    private static func json(_ obj: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
