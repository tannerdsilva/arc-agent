import Foundation

/// The `process` tool: collect surface for background `terminal` runs
/// (reference `process` parity).
///
/// Start a long run with `terminal(command:..., background:true)`, keep
/// working (editing, reading, other calls), then collect with this tool:
/// - `list` — every background session in this process (id, command, status).
/// - `poll` — status + exit code + recent output for one session.
/// - `log` — full output with `offset`/`limit` line paging.
/// - `wait` — block until the session exits (or `timeout` seconds elapse).
/// - `kill` — terminate a session (SIGTERM to its children, then the shell).
public enum ProcessTool {

    static let actions = ["list", "poll", "log", "wait", "kill"]

    /// The ``ToolEntry`` for this tool.
    public static let entry = ToolEntry(
        name: "process",
        toolset: "terminal",
        description: "Manage background processes started with terminal(background=true): "
            + "list, poll, log, wait, kill. Use this to run long jobs (test suites, "
            + "builds, servers) without blocking the turn: start in background, keep "
            + "working, then collect here.",
        schema: .object(
            description: "Manage background processes",
            properties: [
                "action": .enum(
                    description: "What to do: list, poll, log, wait, or kill",
                    values: Self.actions
                ),
                "session_id": .string(
                    description: "Session id returned by terminal background mode (required for poll/log/wait/kill)"
                ),
                "timeout": .integer(
                    description: "Max seconds to block for wait (default 300)",
                    default: 300
                ),
                "offset": .integer(
                    description: "First line to read for log (0 = oldest, default 0)",
                    default: 0
                ),
                "limit": .integer(
                    description: "Lines to read for log (default 200)",
                    default: 200
                ),
            ],
            required: ["action"]
        ),
        handler: { args in
            try await Self.handle(args)
        },
        emoji: "⚙️"
    )

    // MARK: - Handler

    static func handle(_ args: [String: Any]) async throws -> String {
        let action = (args["action"] as? String) ?? ""
        let sid = (args["session_id"] as? String) ?? ""

        switch action {
        case "list":
            let processes = await ProcessRegistry.shared.summaries()
                .map { summary in
                    [
                        "session_id": summary.sessionID,
                        "command": summary.command,
                        "status": summary.status,
                        "exit_code": summary.exitCode ?? NSNull(),
                    ] as [String: Any]
                }
            return try json(["processes": processes])

        case "poll", "log", "wait", "kill":
            guard !sid.isEmpty else {
                return try json(["error": "session_id is required for \(action)"])
            }
            let registry = ProcessRegistry.shared
            switch action {
            case "poll":
                guard let snap = await registry.snapshot(id: sid) else {
                    return try json(["error": "unknown session_id: \(sid)"])
                }
                return try json(dict(snap))
            case "log":
                let offset = (args["offset"] as? Int) ?? 0
                let limit = (args["limit"] as? Int) ?? 200
                guard let snap = await registry.log(id: sid, offset: offset, limit: limit) else {
                    return try json(["error": "unknown session_id: \(sid)"])
                }
                return try json(dict(snap))
            case "wait":
                let timeout = (args["timeout"] as? Int) ?? 300
                guard let snap = await registry.wait(id: sid, timeout: timeout) else {
                    return try json(["error": "unknown session_id: \(sid)"])
                }
                return try json(dict(snap))
            default: // kill
                guard let snap = await registry.kill(id: sid) else {
                    return try json(["error": "unknown session_id: \(sid)"])
                }
                return try json(dict(snap))
            }

        default:
            return try json([
                "error": "Unknown process action: \(action). Use: \(Self.actions.joined(separator: ", "))",
            ])
        }
    }

    // MARK: - Encoding

    private static func dict(_ snap: ProcessRegistry.Snapshot) -> [String: Any] {
        [
            "session_id": snap.sessionID,
            "command": snap.command,
            "status": snap.status,
            "exit_code": snap.exitCode as Any,
            "completion_reason": snap.completionReason,
            "output": snap.output,
        ]
    }

    private static func json(_ obj: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
