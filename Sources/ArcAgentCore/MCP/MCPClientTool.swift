import Foundation

/// The `mcp_tool` entry: calls tools exposed by external MCP servers
/// (reference `tools/mcp_tool.py`). Server selection and tool names are
/// resolved at call time against the configured servers (`mcp_servers` in
/// `~/.arc/config.json`) and their discovered tool lists.
public enum MCPClientTool {

    public nonisolated(unsafe) static var entry = ToolEntry(
        name: "mcp_tool",
        toolset: "mcp",
        description: "Call a tool from a connected MCP (Model Context Protocol) server. "
            + "External MCP servers expose additional tools — filesystem access, source control, "
            + "databases — that the agent can call like any built-in tool.\n\n"
            + "A server is a local executable that speaks MCP over stdio. arc launches it "
            + "directly: never through a shell, and never through a package manager. "
            + "Configuration is read from config.json under the `mcp_servers` key:\n"
            + "  mcp_servers: { name: { command: \"<executable>\", args: [], env: {}, timeout: 120 } }\n"
            + "The executable is normally a server built with swift-mcp; arc's own server ships "
            + "in this binary as `arc` with the arguments `tools` `mcp` `serve`. Servers are "
            + "added and probed in Settings → MCP servers.\n\n"
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
                // List configured servers and their tools.
                let manager = MCPClientManager.shared
                let servers = await manager.configuredNames()
                if servers.isEmpty {
                    return "No MCP servers configured. Add one in Settings → MCP servers "
                        + "(or the `mcp_servers` block of ~/.arc/config.json): a local "
                        + "executable that speaks MCP over stdio, such as a server built "
                        + "with swift-mcp."
                }
                var lines: [String] = ["Configured MCP servers:"]
                for server in servers.sorted() {
                    lines.append("")
                    lines.append("🔌 \(server)")
                    do {
                        let tools = try await manager.tools(named: server)
                        if tools.isEmpty {
                            lines.append("  (no tools discovered)")
                        } else {
                            for tool in tools {
                                let desc = (tool.description ?? "").prefix(70)
                                lines.append("  \(tool.name) — \(desc)")
                            }
                        }
                    } catch {
                        lines.append("  (unavailable: \(String(describing: error).prefix(80)))")
                    }
                }
                return lines.joined(separator: "\n")
            case "call":
                let server: String = try ToolArguments.required(args, key: "server")
                let toolName: String = try ToolArguments.required(args, key: "tool_name")
                let manager = MCPClientManager.shared
                let tools = try await manager.tools(named: server)
                guard tools.contains(where: { $0.name == toolName }) else {
                    let names = tools.map { $0.name }
                    return "Error: MCP server '\(server)' has no tool '\(toolName)'. Available: "
                        + (names.isEmpty ? "(none)" : names.joined(separator: ", "))
                }
                // Arguments cross into the client actor as JSON: a
                // `[String: Any]` cannot be forwarded as a parameter under
                // Swift 6 region isolation.
                let arguments = args["arguments"] as? [String: Any] ?? [:]
                let argumentsJSON = (try? JSONSerialization.data(withJSONObject: arguments))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                return try await manager.call(named: server, tool: toolName, argumentsJSON: argumentsJSON)
            default:
                return "Error: unknown action '\(action)'. Valid actions: call, list"
            }
        },
        emoji: "🔌"
    )
}