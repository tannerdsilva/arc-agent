import Foundation
import SwiftSlash
import Logging

// MARK: - Plugin JSON value (arbitrary JSON for tool schemas)

/// A JSON value that can live inside ``PluginManifest`` (Codable). Used for
/// per-tool OpenAI-format `schema` objects — the reference `plugin.yaml` +
/// `register(ctx)` tool contract, adapted to runtime-discoverable JSON
/// manifests in a static binary.
public enum PluginJSON: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: PluginJSON])
    case array([PluginJSON])
    case null

    /// Bridge to `Any` for ``JSONSchema/init(fromOpenAI:)``.
    public func toAny() -> Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .object(let o): return o.mapValues { $0.toAny() }
        case .array(let a): return a.map { $0.toAny() }
        case .null: return NSNull()
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode([String: PluginJSON].self) {
            self = .object(value)
        } else if let value = try? container.decode([PluginJSON].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .number(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - Plugin manifest (arc plugin.yaml structure, JSON form)

/// A plugin is a directory under `~/.arc/plugins/<name>/` containing a
/// `manifest.json`:
/// ```json
/// {
///   "name": "my-plugin",
///   "version": "1.0.0",
///   "description": "…",
///   "tools": [
///     {
///       "name": "my_tool",
///       "description": "…",
///       "command": "python3",
///       "entry": "tool.py",
///       "args": [],
///       "toolset": "plugins",
///       "requires_env": ["MY_KEY"],
///       "schema": {
///         "type": "object",
///         "properties": { "city": {"type": "string", "description": "…"} },
///         "required": ["city"]
///       }
///     }
///   ],
///   "llm": {"provider": "custom", "model": "m", "base_url": "…", "api_key_env": "MY_KEY"}
/// }
/// ```
/// Tools are executables (or interpreter+script pairs) invoked once per call
/// with `{"tool": name, "args": {...}}` on stdin and `{"result": "…"}` on
/// stdout. `command` may be an absolute path, a path relative to the plugin
/// directory, or a bare name resolved via `PATH` (e.g. `python3`), which is
/// how Python and Swift-built tools are integrated — mirroring the reference client'
/// Python tool plugins without an in-process Python host.
public struct PluginManifest: Codable, Sendable, Equatable {
    public struct Tool: Codable, Sendable, Equatable {
        public let name: String
        public let description: String
        public let command: String
        public var args: [String]?
        /// Script (or executable) path relative to the plugin directory,
        /// passed to `command` as its first argument (e.g. `tool.py`).
        public var entry: String?
        /// Toolset grouping (reference `register_tool(toolset:)`); defaults to
        /// "plugins" when absent.
        public var toolset: String?
        /// Environment variables required at runtime (reference `requires_env`
        /// parity): when any are unset the tool is not installed.
        public var requiresEnv: [String]?
        /// OpenAI function-call parameters object (`type`/`properties`/
        /// `required`/…) shown to the model. May also be the full
        /// `{"type": "function", "function": {"name", "description",
        /// "parameters"}}` shape (reference `register_tool(schema:)` parity).
        public var schema: [String: PluginJSON]?

        public init(
            name: String,
            description: String,
            command: String,
            args: [String]? = nil,
            entry: String? = nil,
            toolset: String? = nil,
            requiresEnv: [String]? = nil,
            schema: [String: PluginJSON]? = nil
        ) {
            self.name = name
            self.description = description
            self.command = command
            self.args = args
            self.entry = entry
            self.toolset = toolset
            self.requiresEnv = requiresEnv
            self.schema = schema
        }

        enum CodingKeys: String, CodingKey {
            case name, description, command, args, entry, toolset, schema
            case requiresEnv = "requires_env"
        }
    }

    public struct LLM: Codable, Sendable, Equatable {
        public let provider: String
        public let model: String
        public var baseURL: String?
        public var apiKeyEnv: String?

        enum CodingKeys: String, CodingKey {
            case provider, model
            case baseURL = "base_url"
            case apiKeyEnv = "api_key_env"
        }
    }

    public var name: String
    public let version: String?
    public let description: String?
    public var tools: [Tool]
    public var llm: LLM?

    public init(
        name: String,
        version: String? = nil,
        description: String? = nil,
        tools: [Tool] = [],
        llm: LLM? = nil
    ) {
        self.name = name
        self.version = version
        self.description = description
        self.tools = tools
        self.llm = llm
    }
}

// MARK: - Plugin tool (executable entry)

/// One plugin tool entry executable by the host.
///
/// ``PluginTool`` IS an ``AgentTool`` — no closure wrapping required. The
/// host registry stores it directly; `handler` pipes the call through a
/// bounded subprocess ([[invoke(args:)]]). Schema, toolset, and
/// `requires_env` come from the plugin's ``PluginManifest``.
public struct PluginTool: Sendable {
    public let plugin: String
    public let name: String
    public let description: String
    public let command: String
    public let args: [String]
    /// Script relative to the plugin directory (see ``PluginManifest/Tool``).
    public let entry: String?
    public let toolset: String
    public let requiresEnv: [String]
    /// Parsed OpenAI function-call parameter schema. Falls back to a free-form
    /// `{args: {}}` object when the manifest omits a usable schema.
    public let schema: JSONSchema
    /// Working directory override (defaults to ~/.arc/plugins/<plugin>).
    public var cwdOverride: URL?

    public init(
        plugin: String,
        name: String,
        description: String,
        command: String,
        args: [String] = [],
        entry: String? = nil,
        toolset: String = "plugins",
        requiresEnv: [String] = [],
        schema: [String: PluginJSON]? = nil,
        cwdOverride: URL? = nil
    ) {
        self.plugin = plugin
        self.name = name
        self.description = description
        self.command = command
        self.args = args
        self.entry = entry
        self.toolset = toolset
        self.requiresEnv = requiresEnv
        self.schema = Self.parseSchema(from: schema)
        self.cwdOverride = cwdOverride
    }

    /// Normalize the manifest `schema` into a ``JSONSchema``.
    ///
    /// Accepts the raw parameters object, a `"function"` wrapper (reference
    /// `register_tool(schema:)` shape), or `{"parameters": …}`.
    static func parseSchema(from schema: [String: PluginJSON]?) -> JSONSchema {
        guard let raw = schema else {
            return .object(properties: ["args": .object(properties: [:])])
        }
        let any = raw.mapValues { $0.toAny() }
        let parameters: [String: Any]? = {
            if let params = any["parameters"] as? [String: Any] {
                return params
            }
            if let function = any["function"] as? [String: Any] {
                return function["parameters"] as? [String: Any]
            }
            return any["type"] != nil ? any : nil
        }()
        if let parsed = parameters.flatMap({ JSONSchema(fromOpenAI: $0) }) {
            return parsed
        }
        return .object(properties: ["args": .object(properties: [:])])
    }

    enum InvokeError: Error, CustomStringConvertible {
        case executableNotFound(String)
        case timeout(TimeInterval)
        var description: String {
            switch self {
            case .executableNotFound(let cmd):
                return "plugin executable not found: \(cmd)"
            case .timeout(let seconds):
                return "plugin invocation timed out after \(seconds)s"
            }
        }
    }

    /// Resolve the executable: absolute path, plugin-relative path, or a bare
    /// name searched on `PATH` (interpreters like `python3`).
    private func resolveExecutable(cwd: URL) throws -> URL {
        if command.hasPrefix("/") {
            return URL(fileURLWithPath: command)
        }
        if command.contains("/") {
            let candidate = cwd.appendingPathComponent(command)
            guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
                throw InvokeError.executableNotFound(command)
            }
            return candidate
        }
        let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in searchPath.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw InvokeError.executableNotFound(command)
    }

    /// Invoke the plugin binary: JSON `{"tool": name, "args": {...}}` on
    /// stdin → JSON `{"result": "..."}` on stdout. Bounded: 60s, 1MB.
    public func invoke(args: [String: Any]) async throws -> String {
        let cwd = cwdOverride ?? ArcHome.plugins.appendingPathComponent(plugin)
        let exe = try resolveExecutable(cwd: cwd)
        var processArgs = self.args
        if let entry {
            processArgs.insert(entry, at: 0)
        }

        // SwiftSlash: posix_spawn; payload rides stdin; process-group kill +
        // reap on the 60s bound. (Old Foundation-Pipe path could deadlock on
        // unresolvable stderr and left no reaping guarantee.)
        var command = Command(
            absolutePath: Path(URL(fileURLWithPath: exe.path).path),
            arguments: processArgs)
        command.inheritCurrentEnvironment()
        command.workingDirectory = Path(cwd.path)

        let payload: [String: Any] = ["tool": name, "args": args]
        // newline-terminated frame: the plugin protocol is newline-delimited
        // (the tool side delivers a frame on its terminating newline).
        let payloadBytes = Array(try JSONSerialization.data(withJSONObject: payload)) + [0x0A]

        let outcome = try await SubprocessRunner.runBytes(
            command, timeout: 60, captureCap: 1_000_000, stdin: payloadBytes)
        if outcome.timedOut {
            throw InvokeError.timeout(60)
        }

        let raw = String(data: outcome.stdout, encoding: .utf8) ?? ""
        if let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
           let result = json["result"] as? String {
            return result
        }
        return raw.isEmpty ? "(plugin returned no output)" : raw
    }
}

// MARK: - AgentTool Conformance

/// ``PluginTool`` executes through a bounded subprocess per call (60s, 1MB
/// cap), same contract as the reference client's Python plugins (one-shot
/// `{tool, args}` → `{result}` on stdin/stdout, cwd = plugin directory).
extension PluginTool: AgentTool {

    /// Plugin tools are available when the installation's `requires_env`
    /// variables are set — enforced at install time by
    /// ``MutableToolRegistry/install(pluginTool:)``, so the check closure is
    /// always nil here.
    public var checkFn: ToolRequirementCheck? { nil }

    public var emoji: String? { "🧩" }

    /// Execute the tool: JSON `{tool, args}` on stdin → `{result}` on stdout.
    /// Failures are rendered as a friendly `"Error: …"` string, never thrown,
    /// so a misbehaving plugin degrades to a tool response instead of an
    /// agent-facing error.
    public var handler: ToolHandler {
        { args in
            do {
                return try await self.invoke(args: args)
            } catch {
                return "Error: plugin tool failed: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Plugin registry (discovery)

/// Discovers plugins under `~/.arc/plugins/` and exposes their tools/LLMs
/// (reference `get_all_toolsets`/`_get_plugin_toolset_names` equivalents).
///
/// ## Deployment semantics (sidecar-plugin parity)
///
/// Discovery **never blocks boot**: directories without a `manifest.json`
/// are skipped silently; unreadable or malformed manifests are recorded in
/// ``discoveryIssues()`` and logged as warnings, and the rest of the
/// installation still loads. `arc doctor` and `arc plugins list` surface the
/// issues to an operator.
public actor PluginRegistry {
    public static let shared = PluginRegistry()

    public let pluginsDir: URL
    private var manifests: [String: PluginManifest] = [:]
    private var toolCache: [PluginTool] = []
    private var issues: [String] = []
    private var cached = false

    private let logger = Logger(label: "arc.plugins")

    public init(pluginsDir: URL? = nil) {
        self.pluginsDir = pluginsDir ?? ArcHome.plugins
    }

    /// Rescan the plugins directory (reference scans every agent init).
    public func loadAll() throws {
        manifests = [:]
        toolCache = []
        issues = []
        cached = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: pluginsDir.path) else { return }
        for dir in try fm.contentsOfDirectory(at: pluginsDir, includingPropertiesForKeys: [.isDirectoryKey]) {
            let manifestURL = dir.appendingPathComponent("manifest.json")
            guard fm.fileExists(atPath: manifestURL.path) else { continue }
            guard let data = try? Data(contentsOf: manifestURL) else {
                let message = "\(dir.lastPathComponent): manifest.json unreadable; skipping plugin"
                issues.append(message)
                logger.warning("\(message)")
                continue
            }
            // Other plugin kinds (e.g. sidebar-tab sidecars) share this
            // directory. Only treat a manifest as a (broken) tool plugin when
            // it declares a `tools` key — otherwise skip silently.
            let rootObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let declaresTools = rootObject?["tools"] != nil
            guard var manifest = try? JSONDecoder().decode(PluginManifest.self, from: data) else {
                guard declaresTools else { continue }
                let message = "\(dir.lastPathComponent): manifest.json is malformed; skipping plugin"
                issues.append(message)
                logger.warning("\(message)")
                continue
            }
            if manifest.name.isEmpty { manifest.name = dir.lastPathComponent }
            if manifest.tools.isEmpty {
                guard declaresTools else { continue }
                let message = "\(dir.lastPathComponent): manifest declares no tools; skipping plugin"
                issues.append(message)
                logger.warning("\(message)")
                continue
            }
            manifests[manifest.name] = manifest
            for tool in manifest.tools {
                toolCache.append(PluginTool(
                    plugin: manifest.name,
                    name: tool.name,
                    description: tool.description,
                    command: tool.command,
                    args: tool.args ?? [],
                    entry: tool.entry,
                    toolset: tool.toolset ?? "plugins",
                    requiresEnv: tool.requiresEnv ?? [],
                    schema: tool.schema,
                    cwdOverride: dir
                ))
            }
        }
        cached = true
    }

    public func plugins() -> [String: PluginManifest] { manifests }
    public func toolNames() -> [String] { toolCache.map { $0.name } }
    public func tools() -> [PluginTool] { toolCache }
    public func llm() -> PluginManifest.LLM? { manifests.values.compactMap { $0.llm }.first }

    /// Non-fatal discovery problems from the last ``loadAll()`` (malformed
    /// manifests, tool-less plugins). Empty means a clean discovery.
    public func discoveryIssues() -> [String] { issues }
}

// MARK: - Mutable registry (compile-time registry + plugin tools at runtime)

/// The runtime layer on top of the compile-time registry: plugin tools sit
/// beside the built-ins without touching them (reference bundles non-core tools
/// at runtime). Built once by ``make`` and immutable thereafter, so it is a
/// value type conforming to ``ToolRegistry`` (``lookup`` prefers built-ins,
/// then plugins).
///
/// ## Provenance
///
/// Origins are assigned on the way in, never accepted from the tool: a
/// built-in is ``ToolOrigin/builtin`` (it came through
/// ``CompileTimeToolRegistry``), ``install(pluginTool:)`` stamps
/// ``ToolOrigin/plugin(_:)`` with the plugin's own name, and
/// ``register(_:origin:)`` records whatever tier a source registration names.
/// A plugin therefore cannot claim to be compiled in — the only path a plugin
/// tool has into this registry overwrites the origin.
public struct MutableToolRegistry: ToolRegistry {
    public let builtIn: CompileTimeToolRegistry
    private var pluginEntries: [String: RegisteredTool] = [:]

    private static let logger = Logger(label: "arc.plugins")

    public init(builtIn: CompileTimeToolRegistry) {
        self.builtIn = builtIn
        self.pluginEntries = [:]
    }

    /// The per-agent dependency slots the built-in tools were built with.
    ///
    /// Plugin tools carry none of their own, so this is the built-in surface's
    /// bundle: `ArcAgent` adopts it and the `todo`/delegation/kanban slots its
    /// tools captured are the ones the agent fills (GROUNDZERO slice 6).
    public var toolDependencies: ToolDependencies { builtIn.toolDependencies }

    // MARK: ToolRegistry

    public mutating func register(_ tool: any AgentTool, origin: ToolOrigin) throws {
        if builtIn.lookup(name: tool.name) != nil || pluginEntries[tool.name] != nil {
            throw ToolRegistryError.duplicateName(tool.name)
        }
        pluginEntries[tool.name] = RegisteredTool(tool: tool, origin: origin)
    }

    public func lookup(name: String) -> RegisteredTool? {
        builtIn.lookup(name: name) ?? pluginEntries[name]
    }

    public var allTools: [RegisteredTool] {
        builtIn.allTools + pluginEntries.values
    }

    /// Install a plugin tool.
    ///
    /// The tool is stamped ``ToolOrigin/plugin(_:)`` with its own plugin's
    /// name: origin is assigned here, not declared by the plugin, so an
    /// install can never claim a built-in's provenance.
    ///
    /// - Returns: `false` (and skips the tool) when its `requires_env`
    ///   requirements are unmet — reference `check_fn`/`requires_env` parity:
    ///   the tool disappears until the environment provides the vars. Also
    ///   returns `false` (with a warning) when the tool's name collides with
    ///   a built-in or an already-installed plugin tool — a duplicate
    ///   function name in the schema array would make the model ambiguous
    ///   and dispatch unreachable.
    @discardableResult
    public mutating func install(pluginTool: PluginTool) -> Bool {
        for key in pluginTool.requiresEnv where ProcessInfo.processInfo.environment[key] == nil {
            return false
        }
        if builtIn.lookup(name: pluginTool.name) != nil || pluginEntries[pluginTool.name] != nil {
            Self.logger.warning(
                "plugin tool '\(pluginTool.name)' from '\(pluginTool.plugin)' collides with an already-registered tool name; not installing")
            return false
        }
        pluginEntries[pluginTool.name] = RegisteredTool(
            tool: pluginTool, origin: .plugin(pluginTool.plugin))
        return true
    }

    public func buildToolSchemas(enabled: Set<String>, disabled: Set<String>) -> [[String: Any]] {
        var schemas = builtIn.buildToolSchemas(enabled: enabled, disabled: disabled)
        for (name, entry) in pluginEntries where !disabled.contains(entry.toolset) {
            if !enabled.isEmpty && !enabled.contains(entry.toolset) { continue }
            schemas.append(["type": "function", "function": [
                "name": name,
                "description": entry.description,
                "parameters": entry.schema.asDictionary(),
            ]])
        }
        return schemas
    }

    /// Build the full registry used by the agent: built-ins + discovered
    /// plugins (reference agent_init plugin toolset bundling). When
    /// `enabledPlugins` is non-nil only plugins in the allow-list install
    /// (reference `plugins.enabled` semantics).
    ///
    /// The rebuilt registry is scoped to the *active session*: a plugin tool
    /// added at runtime joins the same surface the turn loop dispatches
    /// through, and `memory` / `profile_edit` keep addressing that session's
    /// profile instead of falling back to `default`.
    public static func make(
        context: ToolContext,
        profiles: any ProfileStore,
        memory: any MemoryProvider,
        sessions: any SessionStore,
        messaging: (any BotMessageDelivering)? = nil,
        groupChats: GroupChatManager? = nil,
        pluginRegistry: PluginRegistry? = nil,
        enabledPlugins: Set<String>? = nil,
        sources: [any ToolSource] = []
    ) async throws -> MutableToolRegistry {
        let builtIn = try ArcAgentCore.buildRegistry(
            context: context,
            profiles: profiles,
            memory: memory,
            sessions: sessions,
            messaging: messaging,
            groupChats: groupChats
        )
        var registry = MutableToolRegistry(builtIn: builtIn)
        let plugins = pluginRegistry ?? PluginRegistry.shared
        try? await plugins.loadAll()
        for tool in await plugins.tools() {
            if let allow = enabledPlugins, !allow.contains(tool.plugin) { continue }
            registry.install(pluginTool: tool)
        }
        for source in sources {
            for tool in try await source.tools() {
                try registry.register(tool, origin: .source(source.name))
            }
        }
        return registry
    }
}
