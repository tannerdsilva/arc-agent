import Foundation

// MARK: - Blueprints (reference `tools/blueprints.py`, `reference blueprint`)

/// A skill becomes a blueprint when its SKILL.md frontmatter carries
/// `metadata.reference.blueprint` with a non-empty `schedule`. Running the
/// blueprint registers a cron job that runs the skill's prompt.
public struct BlueprintSpec: Sendable, Equatable {
    public let skillName: String
    public let schedule: String
    public let deliver: String
    public let prompt: String?
    public let noAgent: Bool
    public let model: String?
    public let provider: String?
    public let enabledToolsets: [String]?

    public init(skillName: String, schedule: String, deliver: String, prompt: String?,
                noAgent: Bool, model: String?, provider: String?, enabledToolsets: [String]?) {
        self.skillName = skillName
        self.schedule = schedule
        self.deliver = deliver
        self.prompt = prompt
        self.noAgent = noAgent
        self.model = model
        self.provider = provider
        self.enabledToolsets = enabledToolsets
    }
}

public enum BlueprintError: Error, CustomStringConvertible, Equatable {
    case invalid(String)
    public var description: String {
        switch self {
        case .invalid(let reason): return "blueprint invalid: \(reason)"
        }
    }
}

public enum BlueprintParser {

    /// Parse a SKILL.md string. Returns nil when not a blueprint; throws on
    /// a structurally invalid blueprint block (reference: typo must surface).
    public static func parse(_ skillText: String, fallbackName: String = "") throws -> BlueprintSpec? {
        let fm = flatFrontmatter(skillText)
        guard !fm.isEmpty else { return nil }
        let name = fm["name"] ?? fallbackName
        let flat = nestedPaths(skillText)
        func section(_ prefix: String) -> [String: String] {
            var out: [String: String] = [:]
            for (key, value) in flat where key.hasPrefix(prefix + ".") {
                out[String(key.dropFirst(prefix.count + 1))] = value
            }
            return out
        }
        let blueprint = section("metadata.reference.blueprint")
        guard !blueprint.isEmpty else { return nil }
        guard let schedule = blueprint["schedule"], !schedule.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw BlueprintError.invalid("metadata.reference.blueprint.schedule is required and must be non-empty")
        }
        var model: String? = nil
        var provider: String? = nil
        var toolsets: [String]? = nil
        for (key, value) in blueprint {
            switch key {
            case "model": model = value.isEmpty ? nil : value
            case "provider": provider = value.isEmpty ? nil : value
            case "enabled_toolsets":
                toolsets = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            default: break
            }
        }
        return BlueprintSpec(
            skillName: name,
            schedule: schedule,
            deliver: (blueprint["deliver"] ?? "").isEmpty ? "origin" : blueprint["deliver"]!,
            prompt: (blueprint["prompt"] ?? "").isEmpty ? nil : blueprint["prompt"],
            noAgent: blueprint["no_agent"]?.lowercased() == "true",
            model: model,
            provider: provider,
            enabledToolsets: toolsets
        )
    }

    /// Flat top-level frontmatter keys.
    static func flatFrontmatter(_ text: String) -> [String: String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count > 0, lines[0].trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        guard let end = lines[1...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return [:]
        }
        var result: [String: String] = [:]
        for line in lines[1..<end] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard trimmed.hasPrefix("  ") == false, let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            result[key] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return result
    }

    /// Collect nested-frontmatter leaves as dotted paths.
    static func nestedPaths(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return result }
        guard let end = lines[1...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return result
        }
        var stack: [(String, Int)] = []
        for line in lines[1..<end] {
            let content = String(line.drop(while: { $0 == " " }))
            let indent = line.prefix(while: { $0 == " " }).count
            guard !content.isEmpty, !content.hasPrefix("#"),
                  let colon = content.firstIndex(of: ":") else { continue }
            let key = String(content[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(content[content.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            while let last = stack.last, last.1 >= indent {
                stack.removeLast()
            }
            if value.isEmpty {
                stack.append((key, indent))
            } else {
                let path = (stack.map { $0.0 } + [key]).joined(separator: ".")
                result[path] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return result
    }
}
