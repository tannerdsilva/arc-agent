import ArcToolKit

// MARK: - Registered tool (tool + its provenance)

/// A tool together with the origin its registry assigned when it was admitted.
///
/// ``ToolRegistry/lookup(name:)`` and ``ToolRegistry/allTools`` return these
/// rather than bare `any AgentTool` values, so provenance cannot be dropped on
/// the floor: a caller can always ask whether the tool it found was compiled
/// in, and a policy that cares about that can be written against the answer.
///
/// The read members below are forwarded from ``tool``. Schema building,
/// listing and dispatch sites that only *read* a tool therefore keep compiling
/// unchanged; only a site that needs a bare `any AgentTool` — an array passed
/// into a parameter, a stored existential — unwraps ``tool``.
public struct RegisteredTool: Sendable {

    /// The tool itself.
    public let tool: any AgentTool

    /// Where the tool came from. Assigned at admission, never declared by the
    /// tool.
    public let origin: ToolOrigin

    /// Pair a tool with its provenance.
    public init(tool: any AgentTool, origin: ToolOrigin) {
        self.tool = tool
        self.origin = origin
    }

    // MARK: - Forwarded reads

    /// The tool's unique name. See ``AgentTool/name``.
    public var name: String { tool.name }

    /// The toolset the tool belongs to. See ``AgentTool/toolset``.
    public var toolset: String { tool.toolset }

    /// The tool's human-readable description. See ``AgentTool/description``.
    public var description: String { tool.description }

    /// The tool's parameter schema. See ``AgentTool/schema``.
    public var schema: JSONSchema { tool.schema }

    /// The closure that executes the tool. See ``AgentTool/handler``.
    public var handler: ToolHandler { tool.handler }

    /// The tool's optional availability check. See ``AgentTool/checkFn``.
    public var checkFn: ToolRequirementCheck? { tool.checkFn }

    /// The environment variables the tool requires. See
    /// ``AgentTool/requiresEnv``.
    public var requiresEnv: [String] { tool.requiresEnv }

    /// Where the tool's capability may be exercised. See
    /// ``AgentTool/placement``.
    public var placement: ToolPlacement { tool.placement }

    /// The tool's optional display emoji. See ``AgentTool/emoji``.
    public var emoji: String? { tool.emoji }
}
