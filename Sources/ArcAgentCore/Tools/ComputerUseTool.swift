import Foundation

// MARK: - Computer Use (reference `tools/computer_use/`)

/// Minimal MCP (JSON-RPC 2.0) client over stdio for `cua-driver mcp`
/// (reference `tools/computer_use/cua_backend.py`): one long-lived
/// subprocess, sequential id correlation, no hand-rolled threads (First Law:
/// the reader is a Task; the child is a ``SubprocessSession``).
public actor CuaDriverClient {

    public enum CuaError: Error, CustomStringConvertible {
        case notInstalled(String)
        case notConnected
        case stderr(String)
        case rpc(code: Int, message: String)

        public var description: String {
            switch self {
            case .notInstalled(let hint): return "cua-driver is not installed. \(hint)"
            case .notConnected: return "cua-driver not connected"
            case .stderr(let s): return "cua-driver stderr: \(s)"
            case .rpc(let code, let message): return "cua-driver rpc error \(code): \(message)"
            }
        }
    }

    private var session: SubprocessSession?
    private var readers: [Task<Void, Never>] = []
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    private var binary: String {
        ProcessInfo.processInfo.environment["CUA_DRIVER_BIN"] ?? "cua-driver"
    }

    /// True when `cua-driver` is reachable on PATH (or CUA_DRIVER_BIN set).
    public static func isInstalled() -> Bool {
        let bin = ProcessInfo.processInfo.environment["CUA_DRIVER_BIN"] ?? "cua-driver"
        if bin.contains("/") {
            return FileManager.default.isExecutableFile(atPath: bin)
        }
        return findExecutable(bin) != nil
    }

    private static func findExecutable(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }

    /// Start `cua-driver mcp` and perform the MCP `initialize` handshake
    /// (reference: parses install output on failures).
    public func connect() async throws {
        let executable: String?
        if binary.contains("/") {
            executable = FileManager.default.isExecutableFile(atPath: binary) ? binary : nil
        } else {
            executable = CuaDriverClient.findExecutable(binary)
        }
        guard let executable else {
            throw CuaError.notInstalled(
                "Install: /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/trycua/cua/main/libs/cua-driver/scripts/install.sh)\""
            )
        }
        // Telemetry gate (reference: cua-driver reads this env var).
        var env = ProcessInfo.processInfo.environment
        env["CUA_DRIVER_TELEMETRY"] = "off"

        // One session type for every long-lived child arc owns: `.own` placement,
        // byte channels, one reap task. The Foundation form this replaced joined
        // arc's own process group, so the driver and anything it started were
        // unreachable by a per-client teardown.
        let session = SubprocessSession(
            executable: executable,
            arguments: ["mcp"],
            environment: env)
        self.session = session
        _ = try await session.start()

        startReaders(session)

        // MCP initialize handshake.
        _ = try await request(method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:],
            "clientInfo": ["name": "arc-agent", "version": "1.0.0"],
        ])
        _ = try await request(method: "notifications/initialized", params: [:], isNotification: true)
    }

    /// Attach the three readers: stdout frames, stderr diagnostics, and the exit
    /// watcher that fails in-flight requests instead of leaving them suspended.
    private func startReaders(_ session: SubprocessSession) {
        // The output is newline-framed JSON-RPC. The accumulator is the same one
        // the old `readabilityHandler` fed, now fed by the session's byte pump —
        // one consumer per stream, no Foundation I/O queue involved.
        let outAccumulator = LineAccumulator { [weak self] line in
            Task { await self?.dispatch(line: line) }
        }
        let errAccumulator = LineAccumulator { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                print("[cua-driver] \(trimmed)")
            }
        }
        readers = [
            Task { for await bytes in session.stdout { outAccumulator.feed(Data(bytes)) } },
            Task { for await bytes in session.stderr { errAccumulator.feed(Data(bytes)) } },
            // Without this, a request already awaiting a reply would suspend
            // forever on a driver that died mid-call.
            Task { [weak self] in
                _ = await session.waitForExit()
                await self?.connectionLost()
            },
        ]
    }

    /// Resume every in-flight request once the child is gone.
    private func connectionLost() {
        session = nil
        for (_, cont) in pending {
            cont.resume(throwing: CuaError.notConnected)
        }
        pending.removeAll()
    }

    public func disconnect() async {
        if let session { await session.shutdown() }
        session = nil
        for reader in readers { await reader.value }
        readers = []
        for (_, cont) in pending {
            cont.resume(throwing: CuaError.notConnected)
        }
        pending.removeAll()
    }

    // MARK: - Tool surface

    /// `tools/list` → [String] tool names.
    public func listTools() async throws -> [String] {
        let result = try await request(method: "tools/list", params: [:])
        let tools = (result["tools"] as? [[String: Any]]) ?? []
        return tools.compactMap { $0["name"] as? String }
    }

    /// `tools/call` with the computer-use action + args (reference
    /// `cua-driver call <tool>` surface).
    public func callTool(_ name: String, arguments: [String: Any]) async throws -> String {
        let result = try await request(method: "tools/call", params: [
            "name": name,
            "arguments": arguments,
        ])
        // Structured content: [{type:text,text:...},{type:image_url,...}]
        let content = (result["content"] as? [[String: Any]]) ?? []
        var parts: [String] = []
        for block in content {
            if let text = block["text"] as? String {
                parts.append(text)
            } else if let image = block["image_url"] as? String, !image.isEmpty {
                parts.append("[screenshot: \(image)]")
            }
        }
        if parts.isEmpty {
            let text = result["result"] as? String ?? "ok"
            return text
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - JSON-RPC plumbing

    private func dispatch(line: String) async {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? Int,
              let cont = pending[id] else { return }
        pending.removeValue(forKey: id)
        if let error = json["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? -1
            let message = error["message"] as? String ?? "unknown"
            cont.resume(throwing: CuaError.rpc(code: code, message: message))
        } else {
            cont.resume(returning: json["result"] as? [String: Any] ?? [:])
        }
    }

    private func request(method: String, params: [String: Any], isNotification: Bool = false) async throws -> [String: Any] {
        guard let session, await session.isRunning() else {
            throw CuaError.notConnected
        }
        let id = nextID
        nextID += 1
        var payload: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if isNotification {
            payload["params"] = params
        } else {
            payload["id"] = id
            payload["params"] = params
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        // one frame, terminator included: two writes could interleave with a
        // notification and split a line on the wire
        var frame = Array(data)
        frame.append(0x0A)
        try await session.write(frame)
        if isNotification { return [:] }
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
        }
    }
}

// MARK: - computer_use tool (reference `tools/computer_use/`)

/// Desktop-control tool surface over cua-driver: background computer use —
/// does NOT steal the user's cursor.
public enum ComputerUseTool {

    /// Dangerous text patterns for the `type` action (reference #4562).
    /// Computed (not a stored static): `Regex` is not Sendable (First Law:
    /// no shared mutable/immutable non-Sendable statics).
    static var blockedTypePatterns: [(String, Regex<Substring>)] {
        [
            ("curl | bash", #/(?i)curl\s+[^|]*[|]\s*bash/#),
            ("curl | sh", #/(?i)curl\s+[^|]*[|]\s*sh/#),
            ("wget | bash", #/(?i)wget\s+[^|]*[|]\s*bash/#),
            ("sudo rm -r", #/(?i)\bsudo\s+rm\s+-[rf]/#),
            ("rm -rf /", #/\brm\s+-rf\s+\/$/#),
            ("fork bomb", #/(?i):\s*\(\s*\)\s*\{\s*:[|]:\s*&\s*\}/#),
        ]
    }

    /// Reference action names (schema).
    static let actions: [String] = [
        "capture", "wait", "list_apps", "list_windows", "cua_browser_state",
        "click", "double_click", "right_click", "middle_click",
        "drag", "scroll", "type", "key", "set_value", "focus_app",
        "cua_browser_prepare", "cua_browser_navigate", "cua_browser_click",
        "cua_browser_type", "cua_browser_pointer", "cua_browser_dialog",
        "cua_browser_set_input_files", "cua_browser_download",
    ]

    /// Reject dangerous text before sending it to the driver (reference
    /// `_is_blocked_type`).
    public static func blockedTypeReason(_ text: String) -> String? {
        for (label, pattern) in blockedTypePatterns {
            if (try? pattern.firstMatch(in: text)) != nil {
                return label
            }
        }
        return nil
    }

    public static let entry: ToolEntry = ToolEntry(
        name: "computer_use",
        toolset: "computer_use",
        description: "Universal desktop control via cua-driver (macOS, Windows, Linux). "
            + "Background computer-use: does NOT steal the user's cursor (capture runs "
            + "headless). Actions: " + actions.joined(separator: ", ")
            + ". Requires `cua-driver` on PATH (see error text for install).",
        schema: .object(properties: [
            "action": .string(description: "One of: " + actions.joined(separator: ", ")),
            "params": .object(description: "Action args (e.g. text for type, app for focus_app, offset for scroll)", properties: [:]),
        ], required: ["action"]),
        handler: { args in
            let action: String = try ToolArguments.required(args, key: "action")
            let params = args["params"] as? [String: Any] ?? [:]

            guard CuaDriverClient.isInstalled() else {
                return "Error: cua-driver not installed on PATH. Install: "
                    + "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/trycua/cua/main/libs/cua-driver/scripts/install.sh)\""
            }
            // Dangerous-text guard for `type` (reference `_is_blocked_type`).
            if action == "type" || action == "set_value" {
                let text = (params["text"] as? String) ?? (params["value"] as? String) ?? ""
                if let reason = blockedTypeReason(text) {
                    return "Error: blocked text pattern (\(reason)) for the type action."
                }
            }
            let client = CuaDriverClient()
            do {
                try await client.connect()
                let result = try await client.callTool(action, arguments: params)
                // Explicit teardown instead of a `defer` holding an unstructured
                // Task: the cleanup is an await, so it can be structured.
                await client.disconnect()
                return result
            } catch {
                await client.disconnect()
                return "Error: \(error)"
            }
        },
        emoji: "🖱️"
    )
}
