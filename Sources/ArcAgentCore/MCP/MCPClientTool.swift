import Foundation

/// Registry of MCP server clients (reference `mcp_servers` config).
public actor MCPClientManager {
    public static let shared = MCPClientManager()

    private var configs: [String: MCPServerConfig] = [:]
    private var clients: [String: StdioMCPClient] = [:]

    public func configure(_ servers: [String: MCPServerConfig]) {
        configs = servers
    }

    public func configuredNames() -> [String] {
        Array(configs.keys).sorted()
    }

    public func client(named name: String) throws -> StdioMCPClient {
        guard let config = configs[name] else {
            throw MCPClientError.rpc("unknown MCP server '\(name)' (configured: \(configuredNames().joined(separator: ", ")))")
        }
        if let existing = clients[name] { return existing }
        let client = StdioMCPClient(name: name, config: config)
        clients[name] = client
        return client
    }
}

/// The `mcp_tool` entry: calls tools exposed by external MCP servers
/// (reference `tools/mcp_tool.py`). Server selection and tool names are
/// resolved at call time against the configured servers (`mcp_servers` in
/// `~/.arc/config.json`) and their discovered tool lists.
public enum MCPClientTool {

    public nonisolated(unsafe) static var entry = ToolEntry(
        name: "mcp_tool",
        toolset: "mcp",
        description: "Call a tool from a connected MCP (Model Context Protocol) server. "
            + "External MCP servers expose additional tools — filesystem access, GitHub, "
            + "databases, etc. — that the agent can call like any built-in tool.\n\n"
            + "Configuration is read from config.json under the `mcp_servers` key:\n"
            + "  mcp_servers: { name: { command: \"npx\", args: [\"-y\", \"<server>\"], env: {}, timeout: 120 } }\n\n"
            + "Use `server` to select which configured server to call and `tool_name` for "
            + "the tool on that server. Call with no arguments (or an empty arguments object) "
            + "for tools that take no input.\n\n"
            + "If a server or tool is not found, an error lists the available ones.",
        schema: .object(properties: [
            "action": .string(description: "One of: 'call' (default) or 'list'. 'list' returns the configured servers and the tools each one exposes (without calling tool)."),
            "server": .string(description: "Name of the configured MCP server"),
            "tool_name": .string(description: "Name of the tool on that server"),
            "arguments": .object(description: "Tool input arguments", properties: [:]),
        ], required: []),
        handler: { args in
            let action = (args["action"] as? String) ?? "call"
            switch action {
            case "list":
                // List configured servers and (cheaply, from schema cache) their tools.
                let manager = MCPClientManager.shared
                let servers = await manager.configuredNames()
                if servers.isEmpty {
                    return "No MCP servers configured. Add an `mcp_servers` block to config.json to connect external tools."
                }
                var lines: [String] = ["Configured MCP servers:"]
                for server in servers.sorted() {
                    lines.append("")
                    lines.append("🔌 \(server)")
                    do {
                        let client = try await manager.client(named: server)
                        let tools = try await client.tools()
                        if tools.isEmpty {
                            lines.append("  (no tools discovered)")
                        } else {
                            for tool in tools {
                                let name = tool.name
                                let desc = tool.description.prefix(70)
                                lines.append("  \(name) — \(desc)")
                            }
                        }
                    } catch {
                        lines.append("  (unavailable: \(String(describing: error).prefix(80)))")
                    }
                }
                return lines.joined(separator: "\n")
            case "call":
                let server: String = try MediaTools.required(args, key: "server")
                let toolName: String = try MediaTools.required(args, key: "tool_name")
                let arguments = args["arguments"] as? [String: Any] ?? [:]
                let client = try await MCPClientManager.shared.client(named: server)
                let tools = try await client.tools()
                guard tools.contains(where: { $0.name == toolName }) else {
                    let names = tools.map { $0.name }
                    return "Error: MCP server '\(server)' has no tool '\(toolName)'. Available: "
                        + (names.isEmpty ? "(none)" : names.joined(separator: ", "))
                }
                return try await client.callTool(toolName, arguments: NonSendableBox(arguments))
            default:
                return "Error: unknown action '\(action)'. Valid actions: call, list"
            }
        },
        emoji: "🔌"
    )
}
