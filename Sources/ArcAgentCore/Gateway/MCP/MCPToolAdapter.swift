import Foundation
import MCP

/// Bridges an ARC Agent ``ToolEntry`` to the MCP ``MCPTool`` protocol.
///
/// This wrapper allows any tool registered in ARC Agent's
/// ``CompileTimeToolRegistry`` to be exposed as an MCP tool. It
/// dispatches calls to the underlying ``ToolEntry.handler`` closure.
public struct DynamicMCPTool: MCPTool {

    public static var configuration: MCPToolConfiguration {
        MCPToolConfiguration(description: "")
    }

    private let entry: ToolEntry

    public init(entry: ToolEntry) {
        self.entry = entry
    }

    public init() {
        fatalError("DynamicMCPTool requires a ToolEntry — use init(entry:)")
    }

    // MARK: - MCPTool

    public mutating func apply(arguments: [String: Any]) throws {
        // Arguments are passed through to the handler in invoke()
    }

    public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
        // Reconstruct arguments from context
        let result = try await entry.handler(context.arguments)
        return .text(result)
    }
}
