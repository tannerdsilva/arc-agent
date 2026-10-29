import ArcAgentCore
import Foundation

/// Rules for the MCP server presets — how the settings form's text fields
/// become a stored `mcp_servers.<name>` entry.
///
/// The form is flat text, but the value it produces is a process launch
/// spec: `command` is a single argv[0] resolved through `PATH`, and
/// `args` are argv entries handed straight to it. Nothing is ever run through
/// a shell, so no quoting or expansion happens anywhere — which is exactly why
/// the rules must reject the two shapes users type by habit:
///
/// - a whole command line in the `command` field (`arc tools mcp serve`), which
///   would otherwise be looked up as a single executable name;
/// - shell quoting inside the arguments field, which would arrive literally.
///
/// And one shape arc refuses outright: a package-manager launcher. An MCP
/// server here is a program already on this machine, so the policy lives in
/// ``MCPServerLaunchPolicy`` (shared with the spawn path) rather than being
/// restated in the form.
///
/// Filesystem access is injected (`fileExists`) so the rule matrix is pinned
/// in tests without touching disk.
enum MCPRules {

    /// The filesystem seam: true when `path` exists (used only to tell a
    /// legitimately space-bearing executable path from a typed command line).
    static func fileExistsAtPath(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// Server names key the `mcp_servers` block and are the `server` argument
    /// of `mcp_tool`, so they stay a plain lowercase identifier.
    static func normalizeName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MCPRuleError.nameRequired }
        guard trimmed.count <= 64 else { throw MCPRuleError.nameTooLong(trimmed.count) }
        guard !hasControlCharacters(trimmed) else {
            throw MCPRuleError.nameInvalid("control characters")
        }
        if trimmed.contains(where: { $0.isWhitespace }) {
            throw MCPRuleError.nameInvalid("spaces")
        }
        guard let first = trimmed.first, first.isLetter || first.isNumber else {
            throw MCPRuleError.nameInvalid("it must start with a letter or digit")
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")
        if let bad = trimmed.unicodeScalars.first(where: { !allowed.contains($0) }) {
            throw MCPRuleError.nameInvalid("the character '\(Character(bad))'")
        }
        return trimmed
    }

    /// `command` is argv[0]: one executable, not a command line.
    static func normalizeCommand(
        _ raw: String,
        fileExists: (String) -> Bool = fileExistsAtPath
    ) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MCPRuleError.commandRequired }
        guard !hasControlCharacters(trimmed) else {
            throw MCPRuleError.commandInvalid("control characters")
        }
        if trimmed.contains(where: { $0.isWhitespace }) {
            // An executable path may contain a space, but only if it is real;
            // anything else is the whole command line typed into one field.
            let expanded = (trimmed as NSString).expandingTildeInPath
            guard fileExists(expanded) else { throw MCPRuleError.commandLooksLikeCommandLine }
        }
        return trimmed
    }

    /// One argument per line. Blank lines are ignored; every other line is
    /// passed through verbatim — no shell quoting, no word splitting, so an
    /// argument with spaces (a server's root directory) works as typed.
    static func parseArgs(_ raw: String) -> [String] {
        raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// `KEY=VALUE` per line. The value may be empty; the key may not.
    ///
    /// Note for the UI copy: arc strips its own credential variables
    /// (`ARC_`, `OPENAI_`, `ANTHROPIC_`, …) from every MCP server's
    /// environment regardless of what is set here — these entries are how a
    /// server gets *its own* credentials.
    static func parseEnv(_ raw: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let eq = trimmed.firstIndex(of: "=") else {
                throw MCPRuleError.envLineMissingEquals(trimmed)
            }
            let key = String(trimmed[trimmed.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eq)...])
            guard isValidEnvKey(key) else { throw MCPRuleError.envKeyInvalid(key) }
            guard result[key] == nil else { throw MCPRuleError.envKeyDuplicate(key) }
            result[key] = value
        }
        return result
    }

    static func isValidEnvKey(_ key: String) -> Bool {
        guard let first = key.first, first.isLetter || first == "_" else { return false }
        return key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// The full save plan: the name is unique (or is the server being edited),
    /// the command is one executable, the launcher is one arc will run, and the
    /// args/env text parses. A stated name collision is an error — the user
    /// typed that name, so it must fail loudly rather than silently overwrite
    /// another server.
    ///
    /// `previousName` is the server being edited: a plan whose name equals it is
    /// not a collision with itself, so the caller never has to pre-filter the
    /// existing-name list. A collision with any *other* name is an error — the
    /// user typed that name, so it must fail loudly rather than silently
    /// overwrite a different server.
    ///
    /// `previous` is that server's stored config: its timeouts are carried over,
    /// since the form does not expose them and rebuilding the entry from the
    /// form must not discard a hand-set value.
    static func planEntry(
        name rawName: String,
        command rawCommand: String,
        argsText: String,
        envText: String,
        previousName: String? = nil,
        previous: MCPServerConfig? = nil,
        existingNames: [String]
    ) throws -> (name: String, config: MCPServerConfig) {
        let name = try normalizeName(rawName)
        let command = try normalizeCommand(rawCommand)
        let args = parseArgs(argsText)
        // The one shape arc refuses outright: a launcher that resolves a
        // package over the network. Checked on the parsed argv so a wrapper
        // (`env`, `sh -c`) cannot smuggle one past the command field.
        if let refusal = MCPServerLaunchPolicy.refusal(command: command, arguments: args) {
            throw MCPRuleError.launchRefused(refusal.description)
        }
        let env = try parseEnv(envText)
        if existingNames.contains(name), name != previousName {
            throw MCPRuleError.nameExists(name)
        }
        let config = MCPServerConfig(
            command: command,
            args: args,
            env: env,
            timeout: previous?.timeout ?? 300,
            connectTimeout: previous?.connectTimeout ?? 60
        )
        return (name, config)
    }

    private static func hasControlCharacters(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }
}

/// Errors surfaced by the MCP server form. Each carries its user-facing
/// message so the UI can toast the reason as-is.
enum MCPRuleError: Error, Equatable, CustomStringConvertible {
    case nameRequired
    case nameTooLong(Int)
    case nameInvalid(String)
    case nameExists(String)
    case commandRequired
    case commandInvalid(String)
    case commandLooksLikeCommandLine
    case launchRefused(String)
    case envLineMissingEquals(String)
    case envKeyInvalid(String)
    case envKeyDuplicate(String)

    var description: String {
        switch self {
        case .nameRequired:
            return "Name is required — it is how the agent selects this server."
        case .nameTooLong(let count):
            return "Name is \(count) characters; MCP server names are limited to 64."
        case .nameInvalid(let reason):
            return "Invalid server name (\(reason)). Use lowercase letters, digits, '-' and '_'."
        case .nameExists(let name):
            return "An MCP server named '\(name)' already exists. Edit it instead of adding a second one."
        case .commandRequired:
            return "Command is required — the executable to launch (for example `arc`, or the full path to a server you built)."
        case .commandInvalid(let reason):
            return "Invalid command (\(reason))."
        case .commandLooksLikeCommandLine:
            return "Command must be one executable, not a whole command line. Put `arc` in Command and `tools`, `mcp`, `serve` in Arguments — nothing is run through a shell, so a command line typed here is looked up as a single (missing) executable."
        case .launchRefused(let reason):
            return reason
        case .envLineMissingEquals(let line):
            return "Environment line '\(line)' is not KEY=VALUE."
        case .envKeyInvalid(let key):
            return "Invalid environment variable name '\(key)'."
        case .envKeyDuplicate(let key):
            return "Environment variable '\(key)' is set twice."
        }
    }
}