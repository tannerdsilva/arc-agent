/// Typed argument extraction shared by tool handlers.
///
/// Handlers receive `[String: Any]` schemas from the model, so argument
/// extraction is defensive: throw ``ToolError`` (the error family the agent
/// loop renders as a clean tool result) instead of crashing on bad input.
enum ToolArguments {

    /// Extract a required, non-empty string argument.
    ///
    /// - Throws: ``ToolError/missingParameter(_:)`` when the key is absent,
    ///   not a string, or empty.
    static func required(_ args: [String: Any], key: String) throws -> String {
        guard let value = args[key] as? String, !value.isEmpty else {
            throw ToolError.missingParameter(key)
        }
        return value
    }
}