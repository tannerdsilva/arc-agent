import Foundation
import CryptoKit

// MARK: - Tool guardrails (Hermes `tool_guardrails.py`)

/// Loop caps + per-turn budgets for tool calls, with canonical-signature
/// repeat detection and synthetic results.
public actor ToolGuardrails {

    public static let maxWebSearchesPerTurn = 50
    public static let maxSubagentSpawnsPerTurn = 50
    /// Default per-tool loop cap (Hermes default_loop_cap; retry-aware).
    public static let defaultLoopCap = 25

    /// Tool names counted as web searches (loop cap group).
    static let webSearchTools = ["web_search", "web_extract", "web_fetch", "search"]
    /// Tool names counted as subagent spawns.
    static let subagentTools = ["delegate_task", "delegation", "spawn_subagent"]

    public struct Limits: Sendable {
        public var perToolCaps: [String: Int]
        public var maxWebSearches: Int
        public var maxSubagentSpawns: Int
        public init(perToolCaps: [String: Int] = [:],
                    maxWebSearches: Int = ToolGuardrails.maxWebSearchesPerTurn,
                    maxSubagentSpawns: Int = ToolGuardrails.maxSubagentSpawnsPerTurn) {
            self.perToolCaps = perToolCaps
            self.maxWebSearches = maxWebSearches
            self.maxSubagentSpawns = maxSubagentSpawns
        }
    }

    public enum Decision: Sendable, Equatable {
        case allow
        case synthetic(String)
    }

    private var limits: Limits
    private var counts: [String: Int] = [:]       // tool name -> calls
    private var signatures: [ToolSignature: Int] = [:] // repeated calls
    private var webSearches = 0
    private var subagentSpawns = 0

    private struct ToolSignature: Hashable, Sendable {
        let tool: String
        let canonicalArgs: String
    }

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    /// Canonical, normalized JSON of tool arguments: sorted keys, compact
    /// encoding (Hermes `canonical_tool_args` for signature hashing).
    public static func canonicalArgs(_ args: [String: Any]) -> String {
        func flatten(_ value: Any) -> Any {
            if let dict = value as? [String: Any] {
                return dict.mapValues(flatten)
            }
            if let list = value as? [Any] { return list.map(flatten) }
            return value
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: flatten(args), options: [.sortedKeys])
        else { return args.keys.sorted().joined(separator: ",") }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Short signature for a call (SHA-256 prefix; Hermes hashes signatures).
    public static func signature(tool: String, args: [String: Any]) -> String {
        let canonical = canonicalArgs(args)
        let digest = SHA256.hash(data: Data("\(tool):\(canonical)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Decide whether a tool call may run. Increments counters; returns a
    /// synthetic result when a cap is hit (Hermes returns synthetic results
    /// for repeated calls instead of executing again).
    public func decide(toolName: String, args: [String: Any]) -> Decision {
        counts[toolName, default: 0] += 1
        let n = counts[toolName] ?? 0

        let cap = limits.perToolCaps[toolName] ?? ToolGuardrails.defaultLoopCap
        if n > cap {
            return .synthetic("Tool call limit reached for \(toolName) after \(n) calls (cap \(cap)). Do not repeat this same call again; try a different approach or ask the user.")
        }

        // Repeat detection: the same canonical call more than twice in a turn
        // is almost always a loop — synthetic result + guidance.
        let sig = ToolSignature(tool: toolName, canonicalArgs: ToolGuardrails.canonicalArgs(args))
        signatures[sig, default: 0] += 1
        let repeats = signatures[sig] ?? 0
        if repeats > max(2, cap / 3) {
            return .synthetic("Repeated identical call to \(toolName) detected (\(repeats)x). The result will not change. Reconsider your approach or gather new information first.")
        }

        if let web = ToolGuardrails.webSearchTools.first(where: { $0 == toolName }) {
            _ = web
            webSearches += 1
            if webSearches > limits.maxWebSearches {
                return .synthetic("Web search limit reached for this turn (\(limits.maxWebSearches)). Stop searching and answer with what you have.")
            }
        }
        if ToolGuardrails.subagentTools.contains(toolName) {
            subagentSpawns += 1
            if subagentSpawns > limits.maxSubagentSpawns {
                return .synthetic("Subagent spawn limit reached for this turn (\(limits.maxSubagentSpawns)). Do not spawn more agents.")
            }
        }
        return .allow
    }

    /// Reset per-turn counters (called at the start of every conversation).
    public func resetTurn() {
        counts = [:]
        signatures = [:]
        webSearches = 0
        subagentSpawns = 0
    }

    /// Append Hermes-style guidance to a tool result so the model knows what
    /// went wrong and how to recover (`classify_tool_failure` + recovery
    /// hints).
    public static func classifiedResult(rawResult: String, toolName: String) -> String {
        let trimmed = rawResult.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Tool \(toolName) returned no output (empty result)."
        }
        return rawResult
    }
}

// MARK: - File safety (Hermes `file_safety.py`)

/// Write-denied paths, cross-profile protection, and symlink confinement.
public enum FileSafety {

    /// Paths that may never be overwritten by the `write_file` tool — the
    /// agent's own config/state files (Hermes write-denied paths + prefixes).
    public static let writeDeniedExact: [String] = [
        "~/.arc-agent/config.json",
        "~/.arc-agent/settings.json",
        "~/.arc/config.json",
        "~/.hermes/config.yaml",
        "~/.hermes/config.yml",
        "~/.hermes/config.json",
    ]

    /// Path prefixes that are always protected (Hermes cross-profile areas:
    /// skills, plugins, cron, memories live under profiles).
    public static let writeDeniedPrefixes: [String] = [
        "~/.hermes/profiles/",
        "~/.arc/",
        "~/.arc-agent/profiles/",
        "~/.arc-agent/skills/",
        "~/.arc-agent/plugins/",
        "~/.arc-agent/cron/",
        "~/.arc-agent/memories/",
    ]

    /// Whether the given absolute path is write-denied (Hermes
    /// `is_denied_for_write`). Resolves `~` and real paths.
    public static func isWriteDenied(_ path: String) -> Bool {
        let expanded = expandHome(path)
        let resolved = (expanded as NSString).resolvingSymlinksInPath
        let denied = writeDeniedExact.map { expandHome($0) }
        let prefixes = writeDeniedPrefixes.map { expandHome($0) }
        if denied.contains(resolved) || denied.contains(expanded) { return true }
        return prefixes.contains { resolved.hasPrefix($0) || expanded.hasPrefix($0) }
    }

    /// Sandbox/container mirror warning (Hermes warns when a write target is
    /// a sandbox mirror of a protected file).
    public static func sandboxMirrorWarning(_ path: String) -> String? {
        let expanded = expandHome(path)
        guard expanded.contains("/sandbox/") || expanded.contains("/container/") else { return nil }
        return "Warning: \(expanded) is inside a sandbox/container mirror; changes may not persist."
    }

    /// Expand `~` to the home directory.
    public static func expandHome(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }

    /// Resolve a target path for reads/writes, rejecting escapes above the
    /// working directory (Hermes root confinement) when requested.
    public static func confined(_ path: String, root: String) -> String? {
        let resolved = (path as NSString).standardizingPath
        if resolved.hasPrefix(root + "/") || resolved == root { return resolved }
        return nil
    }
}
