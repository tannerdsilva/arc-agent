import Testing
@testable import ArcAgentCore
import Foundation
import MCP

extension ArcCoreTestRoot {
    /// MCP client parity tests (reference `tools/mcp_tool.py`): a real stdio
    /// handshake against an in-test fake server over swift-mcp's subprocess
    /// carrier, `tools/list` discovery, `tools/call` dispatch, config projection,
    /// session replacement, and env sanitization.
    @Suite("MCP client", .serialized)
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
                    {"type": "text", "text": "\(prefix): " + str(args.get("text", ""))}], "isError": False}}), flush=True)
        """
        }

        /// A server that answers `initialize`, `tools/list` and one `tools/call`,
        /// then exits — a child that dies mid-session.
        private static func dyingServerScript(prefix: String) -> String {
            """
        import sys, json
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            msg = json.loads(line)
            m = msg.get("method")
            if m == "initialize":
                print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "dying", "version": "1.0"}}}), flush=True)
            elif m == "tools/list":
                print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {"tools": [
                    {"name": "echo", "description": "echo back",
                     "inputSchema": {"type": "object"}}]}}), flush=True)
            elif m == "tools/call":
                args = msg.get("params", {}).get("arguments", {}) or {}
                print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {"content": [
                    {"type": "text", "text": "\(prefix): " + str(args.get("text", ""))}], "isError": False}}), flush=True)
                sys.exit(0)
        """
        }

        private func writeScript(_ source: String, named: String) throws -> String {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-mcp-test-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let path = dir.appendingPathComponent(named)
            try source.write(to: path, atomically: true, encoding: .utf8)
            return path.path
        }

        private func writeFakeServer(prefix: String = "echo") throws -> String {
            try writeScript(Self.serverScript(prefix: prefix), named: "fake_mcp.py")
        }

        @Test("a configured server handshakes, discovers, and calls a tool")
        func stdioRoundtrip() async throws {
            let script = try writeFakeServer()
            let manager = MCPClientManager()
            await manager.configure([
                "fake": MCPServerConfig(command: "python3", args: [script], connectTimeout: 20)
            ])

            let tools = try await withTimeout(seconds: 20) {
                try await manager.tools(named: "fake")
            }
            #expect(tools.count == 1)
            #expect(tools[0].name == "echo")
            #expect(tools[0].description == "echo back")

            let out = try await withTimeout(seconds: 20) {
                try await manager.call(named: "fake", tool: "echo", argumentsJSON: #"{"text":"hello mcp"}"#)
            }
            #expect(out == "echo: hello mcp")

            await manager.shutdown()
        }

        /// The replacement for the deleted watchdog: a session whose child died is
        /// replaced on next use, so a crashed server heals without a backoff loop.
        @Test("a session whose child exited is replaced on the next call")
        func replacesDeadSession() async throws {
            let script = try writeScript(Self.dyingServerScript(prefix: "echo"), named: "dying_mcp.py")
            let manager = MCPClientManager()
            await manager.configure([
                "fake": MCPServerConfig(command: "python3", args: [script], connectTimeout: 20)
            ])

            let first = try await withTimeout(seconds: 20) {
                try await manager.call(named: "fake", tool: "echo", argumentsJSON: #"{"text":"one"}"#)
            }
            #expect(first == "echo: one")

            // Wait for the transport to observe the child's exit.
            let client = try await manager.client(named: "fake")
            var state = await client.currentState()
            for _ in 0..<50 where state == .ready {
                try await Task.sleep(for: .milliseconds(100))
                state = await client.currentState()
            }
            #expect(state != .ready)

            // The manager drops the dead session and spawns a fresh one.
            let second = try await withTimeout(seconds: 20) {
                try await manager.call(named: "fake", tool: "echo", argumentsJSON: #"{"text":"two"}"#)
            }
            #expect(second == "echo: two")

            await manager.shutdown()
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

        @Test("env sanitization strips agent credentials, keeps PATH")
        func envSanitize() {
            let base = [
                "PATH": "/usr/bin",
                "OPENAI_API_KEY": "sk-test",
                "ARC_API_KEY": "arc-test",
                "ARC_ANTHROPIC_API_KEY": "hm",
                "HOME": "/Users/test",
            ]
            let sanitized = MCPServerConfig.sanitizedEnvironment(["MY_VAR": "1"], base: base)
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
                  "command": "/usr/local/bin/mcp-filesystem",
                  "args": ["--root", "/tmp"],
                  "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": "ghp_x"},
                  "timeout": 120
                }
              }
            }
            """
            let config = try JSONDecoder().decode(ArcConfig.self, from: Data(json.utf8))
            #expect(config.mcpServers.keys.contains("files"))
            #expect(config.mcpServers["files"]?.command == "/usr/local/bin/mcp-filesystem")
            #expect(config.mcpServers["files"]?.args == ["--root", "/tmp"])
            #expect(config.mcpServers["files"]?.env["GITHUB_PERSONAL_ACCESS_TOKEN"] == "ghp_x")
            #expect(config.mcpServers["files"]?.timeout == 120)
        }

        /// The launch policy is enforced at the spawn, not only in the settings
        /// form, so a hand-edited `~/.arc/config.json` cannot start a package
        /// manager either. No process is created — the refusal comes first.
        @Test("a package-manager server is refused before any process is spawned")
        func refusesPackageManagerConfig() async {
            let manager = MCPClientManager()
            await manager.configure([
                "npm": MCPServerConfig(command: "npx", args: ["-y", "some-server"]),
                "shell": MCPServerConfig(command: "/bin/sh", args: ["-c", "npm exec some-server"]),
            ])

            for name in ["npm", "shell"] {
                do {
                    _ = try await manager.client(named: name)
                    Issue.record("'\(name)' must be refused, not spawned")
                } catch {
                    #expect(String(describing: error).contains("package manager"))
                }
            }
            await manager.shutdown()
        }

        /// The tool description is the model's only instruction sheet for this
        /// pipeline; a package-manager example there is how npm creeps back into
        /// a config the user never typed.
        @Test("the mcp_tool description teaches no package manager")
        func toolDescriptionIsSwiftNative() {
            let description = MCPClientTool.entry.description
            for token in ["npx", "npm", "yarn", "pipx", "uvx", "@modelcontextprotocol"] {
                #expect(!description.contains(token), "description must not name '\(token)'")
            }
            #expect(description.contains("swift-mcp"))
            #expect(description.contains("tools"))
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
                    command: "/opt/arc/bin/mcp-filesystem",
                    args: ["--root", "/tmp"],
                    env: ["TOKEN": "x"],
                    timeout: 42,
                    connectTimeout: 7
                )
            ]
            let data = try JSONEncoder().encode(config)
            let text = String(decoding: data, as: UTF8.self)
            #expect(text.contains("\"mcp_servers\""), "the underscore key must survive an encode")

            let back = try JSONDecoder().decode(ArcConfig.self, from: data)
            #expect(back.mcpServers["files"]?.command == "/opt/arc/bin/mcp-filesystem")
            #expect(back.mcpServers["files"]?.args == ["--root", "/tmp"])
            #expect(back.mcpServers["files"]?.env == ["TOKEN": "x"])
            #expect(back.mcpServers["files"]?.timeout == 42)
            #expect(back.mcpServers["files"]?.connectTimeout == 7)
        }

        /// A config edit must reach the wire: `configure` drops any session whose
        /// config changed (closing its child) and keeps the warm session for
        /// unchanged servers. Without this, editing a server in the UI would
        /// silently keep talking to the process started from the old config.
        ///
        /// Uses a private manager, not `.shared` — the shared one is asserted empty
        /// by the tests above and those run in parallel with this suite.
        @Test("reconfigure drops a changed session and keeps an unchanged one")
        func reconfigureInvalidatesChangedClient() async throws {
            let scriptA = try writeFakeServer(prefix: "A")
            let scriptB = try writeFakeServer(prefix: "B")
            let manager = MCPClientManager()

            func callText(_ text: String) async throws -> String {
                try await withTimeout(seconds: 20) {
                    try await manager.call(
                        named: "s", tool: "echo", argumentsJSON: #"{"text":"\#(text)"}"#
                    )
                }
            }

            await manager.configure(["s": MCPServerConfig(command: "python3", args: [scriptA], connectTimeout: 20)])
            #expect(try await callText("one") == "A: one")

            // Same config again: the warm session survives (no needless respawn).
            await manager.configure(["s": MCPServerConfig(command: "python3", args: [scriptA], connectTimeout: 20)])
            #expect(try await callText("two") == "A: two")

            // Changed config: the new process answers, so the edit took effect.
            await manager.configure(["s": MCPServerConfig(command: "python3", args: [scriptB], connectTimeout: 20)])
            #expect(try await callText("three") == "B: three")

            // Removed config: the server is gone and its process is closed.
            await manager.configure([:])
            await #expect(throws: (any Error).self) {
                _ = try await manager.client(named: "s")
            }
        }
    }
}