import Foundation

/// Registry of MCP server clients (Hermes `mcp_servers` config).
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
/// (Hermes `tools/mcp_tool.py`). Server selection and tool names are
/// resolved at call time against the configured servers (`mcp_servers` in
/// `~/.arc/config.json`) and their discovered tool lists.
public enum MCPClientTool {

    public static var entry = ToolEntry(
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
            "server": .string(description: "Name of the configured MCP server"),
            "tool_name": .string(description: "Name of the tool on that server"),
            "arguments": .object(description: "Tool input arguments", properties: [:]),
        ], required: ["server", "tool_name"]),
        handler: { args in
            let server: String = try MediaTools.required(args, key: "server")
            let toolName: String = try MediaTools.required(args, key: "tool_name")
            let arguments = args["arguments"] as? [String: Any] ?? [:]
            let client = try await MCPClientManager.shared.client(named: server)
            let tools = try await client.tools()
            guard tools.contains(where: { ($0["name"] as? String) == toolName }) else {
                let names = tools.compactMap { $0["name"] as? String }
                return "Error: MCP server '\(server)' has no tool '\(toolName)'. Available: "
                    + (names.isEmpty ? "(none)" : names.joined(separator: ", "))
            }
            return try await client.callTool(toolName, arguments: arguments)
        },
        emoji: "🔌"
    )
}
