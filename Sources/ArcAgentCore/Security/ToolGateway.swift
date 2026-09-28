import Foundation

// MARK: - Tool gateway / managed scope (Hermes `managed_tool_gateway.py`, `tool-gateway.md`)

/// What the gateway says about a tool invocation.
public enum GatewayAction: String, Codable, Sendable {
    case allow
    case deny
    case requireApproval
}

/// A rule: glob match on tool name (+ optional exact toolset).
public struct ToolGatewayRule: Codable, Sendable, Equatable {
    public var match: String
    public var toolset: String?
    public var action: GatewayAction
    public var reason: String?

    public init(match: String, toolset: String? = nil, action: GatewayAction, reason: String? = nil) {
        self.match = match
        self.toolset = toolset
        self.action = action
        self.reason = reason
    }
}

/// Gateway configuration (Hermes `tool_gateway` config block).
public struct ToolGatewayConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var rules: [ToolGatewayRule]

    public init(enabled: Bool = false, rules: [ToolGatewayRule] = []) {
        self.enabled = enabled
        self.rules = rules
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.rules = try container.decodeIfPresent([ToolGatewayRule].self, forKey: .rules) ?? []
    }
}

/// Evaluates the rule list. Later rules override earlier ones (recent wins),
/// matching Hermes' ordered-scope semantics.
public enum ToolGateway {

    public struct Decision: Sendable {
        public let action: GatewayAction
        public let reason: String?
    }

    public static func decide(toolName: String, toolset: String, config: ToolGatewayConfig) -> Decision {
        guard config.enabled else {
            return Decision(action: .allow, reason: nil)
        }
        var result = Decision(action: .allow, reason: nil)
        for rule in config.rules {
            guard ruleMatches(rule: rule, toolName: toolName, toolset: toolset) else { continue }
            result = Decision(action: rule.action, reason: rule.reason)
        }
        return result
    }

    static func ruleMatches(rule: ToolGatewayRule, toolName: String, toolset: String) -> Bool {
        if let expected = rule.toolset, expected != toolset { return false }
        return wildcardMatch(pattern: rule.match, value: toolName)
    }

    /// Glob match: `*` matches any run of characters (case-sensitive).
    static func wildcardMatch(pattern: String, value: String) -> Bool {
        if !pattern.contains("*") { return pattern == value }
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false)
        var remainder = value[...]
        for (i, part) in parts.enumerated() {
            if part.isEmpty { continue }
            if i == 0 {
                guard remainder.hasPrefix(part) else { return false }
                remainder = remainder.dropFirst(part.count)
            } else if i == parts.count - 1 {
                return remainder.hasSuffix(part)
            } else {
                guard let found = remainder.range(of: part) else { return false }
                remainder = remainder[found.upperBound...]
            }
        }
        return true
    }

    /// Human-readable scope summary.
    public static func describe(config: ToolGatewayConfig) -> String {
        guard config.enabled else { return "tool gateway: disabled (allow all)" }
        var lines = ["tool gateway: enabled"]
        for rule in config.rules {
            lines.append("  \(rule.action.rawValue)  \(rule.match)\(rule.toolset.map { " @\($0)" } ?? "")\(rule.reason.map { " — \($0)" } ?? "")")
        }
        if config.rules.isEmpty { lines.append("  (no rules — allow all)") }
        return lines.joined(separator: "\n")
    }
}
