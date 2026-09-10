import Foundation

/// Moonshot (Kimi) tool-schema subset repair (Hermes `moonshot_schema.py`).
/// Moonshot rejects a stricter subset of JSON Schema than OpenAI; the repair
/// makes OpenAI-format schemas acceptable: strip unsupported keywords,
/// ensure `type`, and force `required: []` to be omitted when empty.
public enum MoonshotSchema {

    /// Keys Moonshot rejects or ignores on parameters objects.
    static let droppedKeys: Set<String> = [
        "additionalProperties", "$schema", "definitions", "$defs", "oneOf", "anyOf",
    ]

    public static func isMoonshotModel(_ model: String) -> Bool {
        let lower = model.lowercased()
        return lower.contains("kimi") || lower.contains("moonshot")
    }

    /// Repair one tool (OpenAI shape) for Moonshot acceptance.
    public static func sanitizeTool(_ tool: [String: Any]) -> [String: Any] {
        var result = tool
        if var function = result["function"] as? [String: Any] {
            if var params = function["parameters"] as? [String: Any] {
                function["parameters"] = sanitizeSchema(params)
            }
            result["function"] = function
        } else if var params = result["parameters"] as? [String: Any] {
            result["parameters"] = sanitizeSchema(params)
        }
        return result
    }

    /// Repair the whole tools array in place.
    public static func sanitizeTools(_ tools: [[String: Any]]) -> [[String: Any]] {
        tools.map(sanitizeTool)
    }

    static func sanitizeSchema(_ schema: [String: Any], depth: Int = 0) -> [String: Any] {
        guard depth < 8 else { return ["type": "object"] }
        var s = schema
        for key in droppedKeys { s.removeValue(forKey: key) }
        // Moonshot needs an explicit type; object is the safe default.
        if s["type"] == nil { s["type"] = "object" }
        // `required: []` is rejected — omit it entirely.
        if let required = s["required"] as? [String], required.isEmpty {
            s.removeValue(forKey: "required")
        }
        // Recurse into properties / items.
        if var properties = s["properties"] as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, value) in properties {
                if let sub = value as? [String: Any] {
                    out[key] = sanitizeSchema(sub, depth: depth + 1)
                } else {
                    out[key] = value
                }
            }
            s["properties"] = out
        }
        if var items = s["items"] as? [String: Any] {
            s["items"] = sanitizeSchema(items, depth: depth + 1)
        }
        return s
    }
}
