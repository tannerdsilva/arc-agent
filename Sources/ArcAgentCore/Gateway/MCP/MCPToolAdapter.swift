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

    private let entry: ToolEntry?

    public init(entry: ToolEntry) {
        self.entry = entry
    }

    /// Satisfies the `MCPTool` protocol's `init()` requirement.
    ///
    /// A tool constructed this way has no ``ToolEntry`` and throws
    /// ``DynamicMCPToolError.missingToolEntry`` when invoked. This path is
    /// never taken by the gateway, which registers instances via
    /// ``MCPServerAdapter`` — the inert fallback exists only so the type
    /// remains total instead of crashing.
    public init() {
        self.entry = nil
    }

    // MARK: - MCPTool

    public mutating func apply(arguments: [String: Any]) throws {
        // Arguments are passed through to the handler in invoke()
    }

    public mutating func invoke(context: MCPContext) async throws -> MCPToolResult {
        // Reconstruct arguments from context
        guard let entry else {
            throw DynamicMCPToolError.missingToolEntry
        }
        let result = try await entry.handler(context.arguments)
        return .text(result)
    }
}

/// Errors surfaced by ``DynamicMCPTool``.
enum DynamicMCPToolError: Error, CustomStringConvertible {
    /// The tool was constructed via the bare `init()` and has no ``ToolEntry``.
    case missingToolEntry

    var description: String {
        "DynamicMCPTool invoked without a ToolEntry — register it via init(entry:)"
    }
}
