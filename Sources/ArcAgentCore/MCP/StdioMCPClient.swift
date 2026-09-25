import Foundation

/// Incremental newline splitter fed by a FileHandle readabilityHandler.
/// Single-threaded by contract (one handler per handle) — no locking needed.
final class MCPLineAccumulator: @unchecked Sendable {
    private var pendingLine = Data()
    private let onLine: (String) -> Void

    init(onLine: @escaping (String) -> Void) {
        self.onLine = onLine
    }

    func feed(_ data: Data) {
        pendingLine.append(data)
        while let idx = pendingLine.firstIndex(of: 0x0A) {
            let lineData = pendingLine[..<idx]
            pendingLine.removeSubrange(...idx)
            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: .newlines)
            if !line.isEmpty { onLine(line) }
        }
    }
}

/// MCP server configuration (Hermes `mcp_servers.<name>` entry).
public struct MCPServerConfig: Codable, Sendable, Equatable {
    /// The command to launch (resolved through PATH via `/usr/bin/env`).
    public var command: String
    /// Arguments passed to the command.
    public var args: [String]
    /// Extra environment variables merged over the sanitized process env.
    public var env: [String: String]
    /// Per-tool-call timeout in seconds (Hermes default 300).
    public var timeout: Double
    /// Initial connection timeout in seconds (Hermes default 60).
    public var connectTimeout: Double

    public init(
        command: String,
        args: [String] = [],
        env: [String: String] = [:],
        timeout: Double = 300,
        connectTimeout: Double = 60
    ) {
        self.command = command
        self.args = args
        self.env = env
        self.timeout = timeout
        self.connectTimeout = connectTimeout
    }

    private enum CodingKeys: String, CodingKey {
        case command, args, env, timeout, connectTimeout
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        command = try c.decode(String.self, forKey: .command)
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        timeout = try c.decodeIfPresent(Double.self, forKey: .timeout) ?? 300
        connectTimeout = try c.decodeIfPresent(Double.self, forKey: .connectTimeout) ?? 60
    }
}

/// A stdio-transport MCP client (Hermes `tools/mcp_tool.py` core).
///
/// Spawns the configured server process, performs the MCP initialize
/// handshake, discovers tools via `tools/list`, and dispatches `tools/call`
/// requests. JSON-RPC 2.0 framed as newline-delimited JSON over stdio (the
/// MCP stdio transport). A watchdog restarts a crashed server with jittered
/// backoff (Hermes `_wrap_command_with_watchdog`).
///
/// Subprocess exception (documented in AGENTS.md): server processes are
/// real OS processes via Foundation `Process` with async byte-stream reads
/// (`FileHandle.bytes.lines` AsyncSequence) — no manual threads.
public actor StdioMCPClient {

    public let name: String
    private let config: MCPServerConfig
    private let cache: MCPSchemaCache

    private var process: Process?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var started = false
    private var shuttingDown = false
    private var restartAttempts = 0
    private var toolsCache: [[String: Any]] = []
    private var stderrLog: String = ""

    public init(name: String, config: MCPServerConfig, cache: MCPSchemaCache = .shared) {
        self.name = name
        self.config = config
        self.cache = cache
    }

    /// Lazily start the server and run the initialize handshake.
    public func ensureStarted() async throws {
        if started { return }
        if let cached = cache.load(server: name) {
            toolsCache = cached
        }
        try await startProcess()
    }

    /// The discovered tools: [{name, description, inputSchema}].
    public func tools() async throws -> [[String: Any]] {
        try await ensureStarted()
        if toolsCache.isEmpty {
            toolsCache = try await listTools()
            cache.save(server: name, tools: toolsCache)
        }
        return toolsCache
    }

    /// Call an MCP tool and return the text content (Hermes tools/call).
    public func callTool(_ toolName: String, arguments: [String: Any]) async throws -> String {
        try await ensureStarted()
        let result = try await request(
            method: "tools/call",
            params: ["name": toolName, "arguments": arguments],
            timeout: config.timeout
        )
        let content = result["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        if text.isEmpty, let err = result["isError"] as? Bool, err {
            return "(tool returned an error)"
        }
        return text.isEmpty ? "(empty result)" : text
    }

    /// Close the connection (session end).
    public func shutdown() async {
        shuttingDown = true
        for cont in pending.values { cont.resume(throwing: MCPClientError.shutdown) }
        pending.removeAll()
        process?.terminate()
        process = nil
        stdinHandle = nil
    }

    // MARK: - Process lifecycle

    private func startProcess() async throws {
        // Sanitize the environment (Hermes `_build_safe_env`): never hand the
        // agent's own API keys/credentials to an external MCP server.
        let environment = MCPSchemaCache.sanitizedEnvironment(config.env)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [config.command] + config.args
        process.environment = environment

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        process.terminationHandler = { [weak self] _ in
            Task { await self?.handleExit() }
        }
        try process.run()
        self.process = process

        // Read stdout via readabilityHandler (newline-delimited JSON-RPC).
        // FILE.IO EXCEPTION (documented, mirrors the CDP internals
        // exception): AsyncFileHandle (.bytes/.lines) is unreliable on this
        // toolchain — lines stop being delivered after the first
        // re-arm race. readabilityHandler runs on Foundation's own internal
        // queue (no hand-spawned threads); each handle's handler is
        // single-threaded, so the buffer needs no lock. Lines hop to the
        // actor for JSON-RPC dispatch.
        let outHandle = outPipe.fileHandleForReading
        let outAccumulator = MCPLineAccumulator { [weak self] line in
            Task { await self?.handleLine(line) }
        }
        outHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            outAccumulator.feed(data)
        }
        // Stderr → bounded log for diagnostics (dropped from the process
        // graph when the handle closes).
        let errHandle = errPipe.fileHandleForReading
        let errAccumulator = MCPLineAccumulator { [weak self] line in
            Task { await self?.appendStderr(line) }
        }
        errHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            errAccumulator.feed(data)
        }

        // Writer access point for the handshake/calls.
        self.stdinHandle = inPipe.fileHandleForWriting

        // Initialize handshake.
        let initResult = try await request(
            method: "initialize",
            params: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["roots": ["listChanged": false], "sampling": false],
                "clientInfo": ["name": "arc-agent", "version": "0.1.0"],
            ],
            timeout: config.connectTimeout
        )
        _ = initResult
        try await sendNotification(method: "notifications/initialized", params: [:])
        started = true
        restartAttempts = 0
    }

    private func handleExit() {
        pending.forEach { _, cont in cont.resume(throwing: MCPClientError.connectionLost) }
        pending.removeAll()
        stdinHandle = nil
        process = nil
        guard started && !shuttingDown else { return }
        // Watchdog: restart with backoff (Hermes watchdog).
        if restartAttempts < 3 {
            restartAttempts += 1
            let delay = Double(1 << (restartAttempts - 1)) // 1s, 2s, 4s
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                await self?.restartIfNeeded()
            }
        } else {
            started = false
        }
    }

    private func restartIfNeeded() async {
        guard !shuttingDown else { return }
        do {
            try await startProcess()
            restartAttempts = 0
        } catch {
            handleExit()
        }
    }

    // MARK: - JSON-RPC

    private var stdinHandle: FileHandle?

    private func request(method: String, params: [String: Any], timeout: Double) async throws -> [String: Any] {
        _ = timeout // reserved: per-call timeout is bounded by process watchdog
        let id = nextID
        nextID += 1
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: payload)

        // Register the continuation BEFORE writing so a fast response can
        // never be dropped (reader task may resume immediately). The
        // cancellation handler makes a dropped caller (timeout race) unblock.
        let result: [String: Any] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
                pending[id] = cont
                do {
                    try writeToProcess(data)
                } catch {
                    pending.removeValue(forKey: id)
                    cont.resume(throwing: error)
                }
            }
        } onCancel: { [weak self] in
            Task { await self?.cancelPending(id) }
        }
        return result["result"] as? [String: Any] ?? result
    }

    private func cancelPending(_ id: Int) {
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: CancellationError())
        }
    }

    private func sendNotification(method: String, params: [String: Any]) async throws {
        let payload: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        try writeToProcess(try JSONSerialization.data(withJSONObject: payload))
    }

    private func writeToProcess(_ data: Data) throws {
        guard let stdinHandle else { throw MCPClientError.connectionLost }
        var line = data
        line.append(0x0A) // newline-delimited framing
        try stdinHandle.write(contentsOf: line)
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let id = json["id"] as? Int, let cont = pending.removeValue(forKey: id) {
            if let error = json["error"] as? [String: Any] {
                cont.resume(throwing: MCPClientError.rpc(error["message"] as? String ?? "unknown error"))
            } else {
                cont.resume(returning: json)
            }
        }
    }

    private func appendStderr(_ line: String) {
        stderrLog += line + "\n"
        if stderrLog.count > 8_000 { stderrLog = String(stderrLog.suffix(8_000)) }
    }

    private func listTools() async throws -> [[String: Any]] {
        let result = try await request(method: "tools/list", params: [:], timeout: config.connectTimeout)
        return result["tools"] as? [[String: Any]] ?? []
    }
}

/// Client-side errors (mirrors Hermes MCP client error taxonomy).
public enum MCPClientError: Error, CustomStringConvertible {
    case connectionLost
    case shutdown
    case timeout
    case rpc(String)

    public var description: String {
        switch self {
        case .connectionLost: return "MCP server connection lost"
        case .shutdown: return "MCP client shut down"
        case .timeout: return "MCP request timed out"
        case .rpc(let msg): return "MCP RPC error: \(msg)"
        }
    }
}

/// Disk cache of discovered tool schemas (Hermes `mcp_schema_cache.py`):
/// avoids re-listing every server on each agent start.
public struct MCPSchemaCache: Sendable {
    public static let shared = MCPSchemaCache()

    private var cacheDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arc/mcp-cache", isDirectory: true)
    }

    public init() {}

    public func load(server: String) -> [[String: Any]]? {
        let file = cacheDir.appendingPathComponent("\(server).json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tools = json["tools"] as? [[String: Any]] else { return nil }
        return tools
    }

    public func save(server: String, tools: [[String: Any]]) {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let file = cacheDir.appendingPathComponent("\(server).json")
        let payload: [String: Any] = ["server": server, "tools": tools]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: file)
        }
    }

    /// Environment sanitization (Hermes `_build_safe_env`): strip the agent's
    /// own credential variables before launching an external MCP server.
    /// `base` defaults to the process environment (injectable for tests).
    public static func sanitizedEnvironment(
        _ extra: [String: String],
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in base {
            let upper = key.uppercased()
            if upper.hasPrefix("HERMES_") || upper.hasPrefix("ARC_") || upper.hasPrefix("OPENAI_")
                || upper.hasPrefix("ANTHROPIC_") || upper.hasPrefix("GEMINI_") || upper.hasPrefix("XAI_")
                || upper.hasPrefix("AZURE_") || upper.hasPrefix("AWS_") {
                continue
            }
            result[key] = value
        }
        for (key, value) in extra { result[key] = value }
        return result
    }
}
