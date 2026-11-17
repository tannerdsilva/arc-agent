/// A registered tool in the ARC Agent tool system.
///
/// Each ``ToolEntry`` bundles the metadata the LLM needs to decide whether to
/// call the tool (name, description, parameter schema) with the Swift handler
/// that executes the call and the ``ToolAvailability`` that gates whether the
/// tool is advertised at all.
///
/// - Note: ``ToolEntry`` is ``Sendable`` so it can be registered once and read
///   concurrently by the agent loop without additional synchronization.
public struct ToolEntry: Sendable {

    // MARK: - Properties

    /// The unique name of this tool (e.g. `"read_file"`).
    ///
    /// This is the identifier the LLM sends back in a ``tool_calls`` payload.
    /// Names should be `snake_case` and unique within a registry.
    public let name: String

    /// The toolset this tool belongs to (e.g. `.file`, `.web`, `.terminal`).
    ///
    /// Toolsets are the grouping mechanism for enabling/disabling categories of
    /// tools at the agent level.
    public let toolset: Toolset

    /// A human-readable description of what this tool does.
    ///
    /// Passed to the LLM as part of the function-calling schema. Good descriptions
    /// dramatically improve the model's ability to choose the right tool.
    public let description: String

    /// The JSON Schema describing this tool's parameters.
    ///
    /// Conforms to the OpenAI function-calling subset of JSON Schema. The schema
    /// is generated at registration time and cached on the entry.
    public let schema: JSONSchema

    /// The closure that executes this tool.
    ///
    /// Receives the parsed arguments dictionary (keys match the schema property
    /// names) and returns a string result that is fed back to the LLM as a
    /// tool response message.
    public let handler: ToolHandler

    /// What must be true for this tool to be advertised.
    ///
    /// Defaults to ``ToolAvailability/always``. ``ToolSchemaRenderer`` and
    /// ``DeferredToolPolicy`` both evaluate it before a tool can reach the
    /// model, so a `.requiresEnv` entry is absent from the prompt until its
    /// variables are present and non-empty.
    public let availability: ToolAvailability

    /// Whether this tool may run concurrently with siblings in one batch.
    ///
    /// Defaults to `false`: the planner isolates a call unless the tool
    /// declares its reads independent of its siblings.
    public let parallelSafe: Bool

    /// Where this tool's capability may be exercised.
    ///
    /// Defaults to ``ToolPlacement/anyCarrier``. Declare
    /// ``ToolPlacement/inProcessOnly`` for a tool that captures state which must
    /// not leave the process — an encryption key, an unlocked store, a live
    /// connection — and no socket caller can reach it, whatever its toolset's
    /// tier says.
    public let placement: ToolPlacement

    /// An optional emoji for display purposes (e.g. `"📄"` for file tools).
    public let emoji: String?

    // MARK: - Init

    /// Create a tool entry.
    ///
    /// - Parameters:
    ///   - name: Unique tool name (snake_case).
    ///   - toolset: Toolset this tool belongs to.
    ///   - description: Human-readable description for the LLM.
    ///   - schema: JSON Schema describing the tool's parameters.
    ///   - handler: Closure that executes the tool.
    ///   - availability: What must be true for the tool to be advertised.
    ///   - parallelSafe: Whether the tool may run concurrently with siblings.
    ///   - placement: Where the tool's capability may be exercised.
    ///   - emoji: Optional display emoji.
    public init(
        name: String,
        toolset: Toolset,
        description: String,
        schema: JSONSchema,
        handler: @escaping ToolHandler,
        availability: ToolAvailability = .always,
        parallelSafe: Bool = false,
        placement: ToolPlacement = .anyCarrier,
        emoji: String? = nil
    ) {
        self.name = name
        self.toolset = toolset
        self.description = description
        self.schema = schema
        self.handler = handler
        self.availability = availability
        self.parallelSafe = parallelSafe
        self.placement = placement
        self.emoji = emoji
    }
}

// MARK: - Type Aliases

/// A closure that executes a tool and returns a string result.
///
/// - Parameter arguments: The parsed arguments dictionary.
/// - Returns: The tool's output as a string (fed back to the LLM).
/// - Throws: Any error that should be reported to the LLM as a tool failure.
public typealias ToolHandler = @Sendable (sending [String: Any]) async throws -> String

// MARK: - AgentTool Conformance

/// ``ToolEntry`` is the canonical built-in ``AgentTool``: everything its
/// stored properties declare is exactly what the protocol requires, so the
/// conformance is a plain structural match (no additional behavior).
extension ToolEntry: AgentTool {}
