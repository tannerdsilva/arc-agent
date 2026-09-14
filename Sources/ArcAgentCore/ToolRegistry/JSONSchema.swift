/// A minimal JSON Schema representation for OpenAI function-calling schemas.
///
/// This type models the subset of JSON Schema that the OpenAI API accepts for
/// tool parameter definitions. It is intentionally limited — we only need to
/// describe tool parameters, not validate arbitrary JSON documents.
///
/// The schema is built declaratively and can be converted to the dictionary
/// format the OpenAI API expects via ``asDictionary()``.
///
/// ## Example
/// ```swift
/// let schema = JSONSchema.object(properties: [
///     "path": .string(description: "File path to read"),
///     "limit": .integer(description: "Max lines", default: 2000),
/// ])
/// ```
public enum JSONSchema: Sendable {

    /// A string parameter.
    case string(description: String, default: String? = nil)

    /// An integer parameter.
    case integer(description: String, default: Int? = nil)

    /// A floating-point number parameter.
    case number(description: String, default: Double? = nil)

    /// A boolean parameter.
    case boolean(description: String, default: Bool? = nil)

    /// An object with named properties.
    indirect case object(
        description: String? = nil,
        properties: [String: JSONSchema],
        required: [String]? = nil
    )

    /// An array of items matching a schema.
    indirect case array(
        description: String? = nil,
        items: JSONSchema
    )

    /// An enum-style string constrained to a set of values.
    case `enum`(description: String, values: [String])

    // MARK: - Conversion

    /// Convert this schema to the dictionary format the OpenAI API expects.
    ///
    /// The returned dictionary is a JSON-compatible `[String: Any]` that can be
    /// serialized with `JSONSerialization` or embedded in an API request body.
    public func asDictionary() -> [String: Any] {
        switch self {
        case .string(let desc, let defaultValue):
            var dict: [String: Any] = ["type": "string"]
            dict["description"] = desc
            if let d = defaultValue { dict["default"] = d }
            return dict

        case .integer(let desc, let defaultValue):
            var dict: [String: Any] = ["type": "integer"]
            dict["description"] = desc
            if let d = defaultValue { dict["default"] = d }
            return dict

        case .number(let desc, let defaultValue):
            var dict: [String: Any] = ["type": "number"]
            dict["description"] = desc
            if let d = defaultValue { dict["default"] = d }
            return dict

        case .boolean(let desc, let defaultValue):
            var dict: [String: Any] = ["type": "boolean"]
            dict["description"] = desc
            if let d = defaultValue { dict["default"] = d }
            return dict

        case .object(let description, let properties, let required):
            var dict: [String: Any] = ["type": "object"]
            if let d = description { dict["description"] = d }
            dict["properties"] = properties.mapValues { $0.asDictionary() }
            if let req = required, !req.isEmpty { dict["required"] = req }
            return dict

        case .array(let description, let items):
            var dict: [String: Any] = ["type": "array"]
            if let d = description { dict["description"] = d }
            dict["items"] = items.asDictionary()
            return dict

        case .enum(let description, let values):
            var dict: [String: Any] = ["type": "string"]
            dict["description"] = description
            dict["enum"] = values
            return dict
        }
    }

    // MARK: - Decoding (OpenAI function parameters)

    /// Parse an OpenAI-style parameters object (as carried by a tool schema
    /// or an MCP response) into the native schema. Unknown keys are ignored;
    /// an unrecognized `type` falls back to ``/string``.
    public init?(fromOpenAI dict: [String: Any]) {
        guard let type = dict["type"] as? String else { return nil }
        let description = dict["description"] as? String ?? ""
        switch type {
        case "object":
            var props: [String: JSONSchema] = [:]
            if let rawProps = dict["properties"] as? [String: Any] {
                for (key, value) in rawProps {
                    if let sub = value as? [String: Any], let parsed = JSONSchema(fromOpenAI: sub) {
                        props[key] = parsed
                    }
                }
            }
            self = .object(
                description: description.isEmpty ? nil : description,
                properties: props,
                required: dict["required"] as? [String]
            )
        case "array":
            if let items = (dict["items"] as? [String: Any]).flatMap({ JSONSchema(fromOpenAI: $0) }) {
                self = .array(description: description.isEmpty ? nil : description, items: items)
            } else {
                self = .array(description: description.isEmpty ? nil : description, items: .object(properties: [:]))
            }
        case "string":
            if let values = dict["enum"] as? [String] {
                self = .enum(description: description, values: values)
            } else {
                self = .string(description: description, default: dict["default"] as? String)
            }
        case "integer":
            self = .integer(description: description, default: dict["default"] as? Int)
        case "number":
            self = .number(description: description, default: dict["default"] as? Double)
        case "boolean":
            self = .boolean(description: description, default: dict["default"] as? Bool)
        default:
            self = .string(description: description)
        }
    }
}
