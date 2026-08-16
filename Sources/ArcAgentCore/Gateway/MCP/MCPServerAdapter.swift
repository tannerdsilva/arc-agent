import Foundation
import MCP
import ServiceLifecycle
import Logging

/// A gateway adapter that wraps an MCP server as a platform adapter.
///
/// ``MCPServerAdapter`` creates an ``MCPServer`` instance, registers ARC
/// Agent's tools from the ``CompileTimeToolRegistry`` as MCP tools, and
/// runs the server as a ``Service`` managed by the gateway's ``ServiceGroup``.
///
/// The adapter supports both stdio transport (for Claude Desktop, etc.) and
/// TCP transport (for remote MCP clients).
public final class MCPServerAdapter: Service {

    private let server: MCPServer
    private let logger: Logger

    /// Create an MCP server adapter.
    /// - Parameters:
    ///   - name: Server name.
    ///   - version: Server version.
    ///   - host: TCP host to bind to (nil for stdio transport).
    ///   - port: TCP port to bind to (ignored if host is nil).
    ///   - registry: The tool registry to expose as MCP tools.
    public init(
        name: String = "ARC Agent",
        version: String = "1.0.0",
        host: String? = nil,
        port: Int = 8081,
        registry: CompileTimeToolRegistry
    ) throws {
        self.logger = Logger(label: "com.arc-agent.mcp")

        if let host = host {
            let address = ServerAddress.hostname(host, port: port)
            self.server = MCPServer(name: name, version: version, address: address) {}
        } else {
            self.server = MCPServer(name: name, version: version) {}
        }

        // Register all tools from the registry as MCP tool instances
        for tool in registry.allTools {
            let adapter = DynamicMCPTool(entry: tool)
            server.registerInstance(tool.name, instance: adapter)
        }

        logger.info("MCP server initialized with \(registry.allTools.count) tools")
        if host != nil {
            logger.info("MCP server listening on \(host ?? "?"):\(port)")
        } else {
            logger.info("MCP server using stdio transport")
        }
    }

    // MARK: - Service

    public func run() async throws {
        try await server.runService()
    }
}
