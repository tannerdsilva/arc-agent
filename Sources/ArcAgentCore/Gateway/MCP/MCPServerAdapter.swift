import Foundation
import MCP
import ServiceLifecycle
import Logging

/// A gateway adapter that wraps an MCP server as a platform adapter.
///
/// ``MCPServerAdapter`` creates an ``MCPServer`` instance over a single
/// ``ArcToolDispatcher`` — the compile-time-exhaustive surface of the tools the
/// registry holds — and runs the server as a ``Service`` managed by the
/// gateway's ``ServiceGroup``.
///
/// The adapter supports both stdio transport (for Claude Desktop, etc.) and
/// TCP transport (for remote MCP clients). Tool visibility and reachability are
/// decided by ``ArcToolDispatcher/access(for:)``, not here: no arc toolset is
/// reachable from a non-loopback address, and filesystem/shell/code-execution
/// toolsets require the local process.
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

        let dispatcher = ArcToolDispatcher(registry: registry)

        if let host = host {
            let address = ServerAddress.hostname(host, port: port)
            self.server = MCPServer(
                name: name,
                version: version,
                address: address,
                accessResolver: ArcToolDispatcher.callerAccess(for:),
                dispatcher: dispatcher
            )
        } else {
            self.server = MCPServer(name: name, version: version, dispatcher: dispatcher)
        }

        logger.info(
            "MCP server initialized with \(registry.allTools.count) tools (toolset access-gated)"
        )
        if host != nil {
            logger.info("MCP server listening on \(host ?? "?"):\(port)")
        } else {
            logger.info("MCP server using stdio transport")
        }
    }

    // MARK: - Service

    public func run() async throws {
        // `run()`, not `runService()`: the daemon root owns signals, and
        // `run()` participates in the inherited graceful shutdown
        // (`withGracefulShutdownHandler` → transport stop) instead of spinning
        // up its own signal-trapping group nested in ours.
        try await server.run()
    }
}
