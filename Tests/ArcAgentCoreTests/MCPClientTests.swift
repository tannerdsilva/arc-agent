import Testing
@testable import ArcAgentCore
import Foundation

/// MCP client parity tests (reference `tools/mcp_tool.py`): real stdio
/// handshake against an in-test fake server, tools/list discovery,
/// tools/call dispatch, schema cache, and env sanitization.
@Suite("MCP client")
struct MCPClientTests {

    /// A minimal newline-delimited JSON-RPC MCP server. `prefix` labels the
    /// script's replies, so a test can tell two server processes apart when
    /// the same server name is re-pointed at a different script.
    private static func serverScript(prefix: String) -> String {
        """
    import sys, json
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception:
            continue
        m = msg.get("method")
        if m == "initialize":
            # Mimic a real server's schema validation: capabilities must be an
            # object whose values are objects. The old `"sampling": false` was
            # accepted by this fake and rejected by every real server.
            caps = msg.get("params", {}).get("capabilities")
            bad = (not isinstance(caps, dict)
                   or any(not isinstance(v, dict) for v in caps.values()))
            if bad:
                print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "error": {
                    "code": -32602,
                    "message": "Invalid input: expected object, received boolean"}}), flush=True)
                continue
            print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "fake", "version": "1.0"}}}), flush=True)
        elif m == "notifications/initialized":
            pass
        elif m == "tools/list":
            print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {"tools": [
                {"name": "echo", "description": "echo back",
                 "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}}
            ]}}), flush=True)
        elif m == "tools/call":
            args = msg.get("params", {}).get("arguments", {}) or {}
            print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {"content": [
                {"type": "text", "text": "\(prefix): " + str(args.get("text", ""))}]}}), flush=True)
    """
    }

    private static let fakeServerScript = serverScript(prefix: "echo")

    private func writeFakeServer(prefix: String = "echo") throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-mcp-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("fake_mcp.py")
        try Self.serverScript(prefix: prefix).write(to: path, atomically: true, encoding: .utf8)
        return path.path
    }

    @Test("stdio client handshakes, discovers, and calls a tool")
    func stdioRoundtrip() async throws {
        let script = try writeFakeServer()
        let client = StdioMCPClient(
            name: "fake",
            config: MCPServerConfig(command: "python3", args: [script], connectTimeout: 20)
        )

        do {
            try await withTimeout(seconds: 15) {
                try await client.ensureStarted()
            }
            let tools = try await client.tools()
            #expect(tools.count == 1)
            #expect(tools[0].name == "echo")
            #expect(tools[0].description == "echo back")

            let out = try await withTimeout(seconds: 15) {
                try await client.callTool("echo", arguments: NonSendableBox(["text": "hello mcp"] as [String: Any]))
            }
            #expect(out == "echo: hello mcp")
        } catch {
            await client.shutdown()
            throw error
        }
        await client.shutdown()
    }

    /// Fail-fast race so a broken transport surfaces as a test failure
    /// instead of a hang.
    private func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw MCPClientError.timeout
            }
            defer { group.cancelAll() }
            let value = try await group.next()!
            return value
        }
    }

    @Test("schema cache saves and reloads tool lists")
    func schemaCache() throws {
        let cache = MCPSchemaCache()
        let name = "cachetest-\(UUID().uuidString)"
        let tools: [[String: Any]] = [["name": "x", "description": "desc"]]
        cache.save(server: name, tools: tools)
        let loaded = cache.load(server: name)
        #expect(loaded != nil)
        #expect(loaded?.count == 1)
        #expect((loaded?[0]["name"] as? String) == "x")
    }

    @Test("env sanitization strips agent credentials, keeps PATH")
    func envSanitize() {
        let base = [
            "PATH": "/usr/bin",
            "OPENAI_API_KEY": "sk-test",
            "ARC_API_KEY": "arc-test",
            "ARC_ANTHROPIC_API_KEY": "hm",
            "HOME": "/Users/test",
        ]
        let sanitized = MCPSchemaCache.sanitizedEnvironment(["MY_VAR": "1"], base: base)
        #expect(sanitized["OPENAI_API_KEY"] == nil)
        #expect(sanitized["ARC_API_KEY"] == nil)
        #expect(sanitized["ARC_ANTHROPIC_API_KEY"] == nil)
        #expect(sanitized["PATH"] == "/usr/bin")
        #expect(sanitized["HOME"] == "/Users/test")
        #expect(sanitized["MY_VAR"] == "1")
    }

    @Test("config decodes top-level mcp_servers")
    func configDecode() throws {
        let json = """
        {
          "mcp_servers": {
            "files": {
              "command": "npx",
              "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
              "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": "ghp_x"},
              "timeout": 120
            }
          }
        }
        """
        let config = try JSONDecoder().decode(ArcConfig.self, from: Data(json.utf8))
        #expect(config.mcpServers.keys.contains("files"))
        #expect(config.mcpServers["files"]?.command == "npx")
        #expect(config.mcpServers["files"]?.args == ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"])
        #expect(config.mcpServers["files"]?.env["GITHUB_PERSONAL_ACCESS_TOKEN"] == "ghp_x")
        #expect(config.mcpServers["files"]?.timeout == 120)
    }

    @Test("mcp_tool handler errors clearly when server not configured")
    func toolUnknownServer() async {
        // Manager starts empty — not configured in this test process.
        let out = await MCPProxy.runSuppressingErrors {
            try await MCPClientTool.entry.handler([
                "server": "nope",
                "tool_name": "x",
            ])
        }
        #expect(out.contains("unknown MCP server"))
        #expect(out.contains("nope"))
    }

    @Test("mcp_tool action='list' reports configured servers (empty here)")
    func toolListAction() async {
        let out = await MCPProxy.runSuppressingErrors {
            try await MCPClientTool.entry.handler(["action": "list"])
        }
        #expect(out.contains("No MCP servers configured"))
    }

    @Test("mcp_tool rejects unknown actions")
    func toolUnknownAction() async {
        let out = await MCPProxy.runSuppressingErrors {
            try await MCPClientTool.entry.handler(["action": "explode"])
        }
        #expect(out.contains("unknown action"))
    }

    /// The webui settings panel saves through `saveConfig(ArcConfig)`, so the
    /// underscore key must survive an encode — a camelCase `mcpServers` on disk
    /// would be silently ignored by the decoder that reads `mcp_servers`.
    @Test("a saved config round-trips the mcp_servers block")
    func configRoundTrip() throws {
        var config = ArcConfig()
        config.mcpServers = [
            "files": MCPServerConfig(
                command: "npx",
                args: ["-y", "srv", "/tmp"],
                env: ["TOKEN": "x"],
                timeout: 42,
                connectTimeout: 7
            )
        ]
        let data = try JSONEncoder().encode(config)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"mcp_servers\""), "the underscore key must survive an encode")

        let back = try JSONDecoder().decode(ArcConfig.self, from: data)
        #expect(back.mcpServers["files"]?.command == "npx")
        #expect(back.mcpServers["files"]?.args == ["-y", "srv", "/tmp"])
        #expect(back.mcpServers["files"]?.env == ["TOKEN": "x"])
        #expect(back.mcpServers["files"]?.timeout == 42)
        #expect(back.mcpServers["files"]?.connectTimeout == 7)
    }

    /// A config edit must reach the wire: `configure` drops any client whose
    /// config changed (stopping its child process) and keeps the warm client
    /// for unchanged servers. Without this, editing a server in the UI would
    /// silently keep talking to the process started from the old config.
    ///
    /// Uses a private manager, not `.shared` — the shared one is asserted empty
    /// by the tests above and those run in parallel with this suite.
    @Test("reconfigure drops a changed client and keeps an unchanged one")
    func reconfigureInvalidatesChangedClient() async throws {
        let scriptA = try writeFakeServer(prefix: "A")
        let scriptB = try writeFakeServer(prefix: "B")
        let manager = MCPClientManager()

        func callText(_ text: String) async throws -> String {
            let client = try await manager.client(named: "s")
            return try await withTimeout(seconds: 15) {
                try await client.callTool("echo", arguments: NonSendableBox(["text": text] as [String: Any]))
            }
        }

        await manager.configure(["s": MCPServerConfig(command: "python3", args: [scriptA], connectTimeout: 20)])
        #expect(try await callText("one") == "A: one")

        // Same config again: the warm client survives (no needless respawn).
        await manager.configure(["s": MCPServerConfig(command: "python3", args: [scriptA], connectTimeout: 20)])
        #expect(try await callText("two") == "A: two")

        // Changed config: the new process answers, so the edit took effect.
        await manager.configure(["s": MCPServerConfig(command: "python3", args: [scriptB], connectTimeout: 20)])
        #expect(try await callText("three") == "B: three")

        // Removed config: the server is gone and its process is stopped.
        await manager.configure([:])
        await #expect(throws: (any Error).self) {
            _ = try await manager.client(named: "s")
        }
    }
}
