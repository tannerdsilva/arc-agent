/// A registered tool in the ARC Agent tool system.
///
/// Each ``ToolEntry`` bundles the metadata the LLM needs to decide whether to
/// call the tool (name, description, parameter schema) with the Swift handler
/// that executes the call and the environment checks that gate its availability.
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

    /// The toolset this tool belongs to (e.g. `"file"`, `"web"`, `"terminal"`).
    ///
    /// Toolsets are the grouping mechanism for enabling/disabling categories of
    /// tools at the agent level.
    public let toolset: String

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

    /// An optional closure that checks whether this tool's requirements are met
    /// (e.g. a binary is installed, an environment variable is set).
    ///
    /// Return `true` if the tool is available, `false` otherwise. A `nil` check
    /// function means the tool is always available (no runtime dependencies).
    public let checkFn: ToolRequirementCheck?

    /// Environment variable names this tool requires at runtime.
    ///
    /// The credential pool checks these when resolving credentials. Tools with
    /// missing required env vars are filtered out of the schema array sent to
    /// the LLM.
    public let requiresEnv: [String]

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
    ///   - checkFn: Optional availability check. `nil` means always available.
    ///   - requiresEnv: Environment variables this tool needs.
    ///   - emoji: Optional display emoji.
    public init(
        name: String,
        toolset: String,
        description: String,
        schema: JSONSchema,
        handler: @escaping ToolHandler,
        checkFn: ToolRequirementCheck? = nil,
        requiresEnv: [String] = [],
        emoji: String? = nil
    ) {
        self.name = name
        self.toolset = toolset
        self.description = description
        self.schema = schema
        self.handler = handler
        self.checkFn = checkFn
        self.requiresEnv = requiresEnv
        self.emoji = emoji
    }
}

// MARK: - Type Aliases

/// A closure that executes a tool and returns a string result.
///
/// - Parameter arguments: The parsed arguments dictionary.
/// - Returns: The tool's output as a string (fed back to the LLM).
/// - Throws: Any error that should be reported to the LLM as a tool failure.
public typealias ToolHandler = @Sendable ([String: Any]) async throws -> String

/// A closure that checks whether a tool's runtime requirements are met.
///
/// - Returns: `true` if the tool is available, `false` otherwise.
public typealias ToolRequirementCheck = @Sendable () -> Bool
