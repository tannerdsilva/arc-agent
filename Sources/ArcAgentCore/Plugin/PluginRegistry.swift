import Foundation

// MARK: - Plugin registry (Hermes plugin toolsets/LLMs, runtime-discoverable)

/// A plugin is a directory under `~/.arc/plugins/<name>/` containing a
/// `manifest.json`:
/// ```json
/// {
///   "name": "my-plugin",
///   "version": "1.0.0",
///   "tools": [
///     {"name": "my_tool", "description": "...", "command": "./bin/my_tool"}
///   ],
///   "llm": {"provider": "custom", "model": "m", "base_url": "...", "api_key_env": "MY_KEY"}
/// }
/// ```
/// Tools are executables invoked once per call with the tool request on stdin
/// and the result on stdout (`{"result": "..."}`); the Swift plugin host is
/// a plain subprocess — no Python host required (Hermes' plugin architecture
/// maps to runtime-discoverable JSON manifests in a static binary).
public struct PluginManifest: Codable, Sendable, Equatable {
    public struct Tool: Codable, Sendable, Equatable {
        public let name: String
        public let description: String
        public let command: String
        public var args: [String]?

        public init(name: String, description: String, command: String, args: [String]? = nil) {
            self.name = name
            self.description = description
            self.command = command
            self.args = args
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
    public var tools: [Tool]
    public var llm: LLM?

    public init(name: String, version: String? = nil, tools: [Tool] = [], llm: LLM? = nil) {
        self.name = name
        self.version = version
        self.tools = tools
        self.llm = llm
    }
}

/// One plugin tool entry executable by the host.
public struct PluginTool: Sendable {
    public let plugin: String
    public let name: String
    public let description: String
    public let command: String
    public let args: [String]
    /// Working directory override (defaults to ~/.arc/plugins/<plugin>).
    public var cwdOverride: URL?

    public init(plugin: String, name: String, description: String, command: String,
                args: [String] = [], cwdOverride: URL? = nil) {
        self.plugin = plugin
        self.name = name
        self.description = description
        self.command = command
        self.args = args
        self.cwdOverride = cwdOverride
    }

    /// Invoke the plugin binary: JSON `{"tool": name, "args": {...}}` on
    /// stdin → JSON `{"result": "..."}` on stdout. Bounded: 60s, 1MB.
    public func invoke(args: [String: Any]) async throws -> String {
        let process = Process()
        let cwd = cwdOverride ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arc/plugins/\(plugin)")
        process.currentDirectoryURL = cwd
        // Relative commands are resolved against the plugin dir (Foundation
        // otherwise resolves relative executables in the PARENT cwd).
        let execURL = command.hasPrefix("/")
            ? URL(fileURLWithPath: command)
            : cwd.appendingPathComponent(command)
        process.executableURL = execURL
        process.arguments = self.args
        return try await withThrowingTaskGroup(of: String.self) { group in
            let stdin = Pipe()
            let stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = Pipe()
            let payload: [String: Any] = ["tool": name, "args": args]
            stdin.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: payload))
            try stdin.fileHandleForWriting.close()
            try process.run()
            group.addTask {
                var data = Data()
                for try await byte in stdout.fileHandleForReading.bytes {
                    data.append(byte)
                    if data.count > 1_000_000 { break }
                }
                return String(data: data, encoding: .utf8) ?? ""
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                process.terminate()
                return ""
            }
            let raw = try await group.next() ?? ""
            group.cancelAll()
            if let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
               let result = json["result"] as? String {
                return result
            }
            return raw.isEmpty ? "(plugin returned no output)" : raw
        }
    }
}

/// Discovers plugins under `~/.arc/plugins/` and exposes their tools/LLMs
/// (Hermes `get_all_toolsets`/`_get_plugin_toolset_names` equivalents).
public actor PluginRegistry {
    public static let shared = PluginRegistry()

    public let pluginsDir: URL
    private var manifests: [String: PluginManifest] = [:]
    private var toolCache: [PluginTool] = []
    private var cached = false

    public init(pluginsDir: URL? = nil) {
        self.pluginsDir = pluginsDir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arc/plugins", isDirectory: true)
    }

    /// Rescan the plugins directory (Hermes scans every agent init).
    public func loadAll() throws {
        manifests = [:]
        toolCache = []
        cached = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: pluginsDir.path) else { return }
        for dir in try fm.contentsOfDirectory(at: pluginsDir, includingPropertiesForKeys: [.isDirectoryKey]) {
            let manifestURL = dir.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL) else { continue }
            guard var manifest = try? JSONDecoder().decode(PluginManifest.self, from: data) else { continue }
            if manifest.name.isEmpty { manifest.name = dir.lastPathComponent }
            manifests[manifest.name] = manifest
            for tool in manifest.tools {
                toolCache.append(PluginTool(
                    plugin: manifest.name,
                    name: tool.name,
                    description: tool.description,
                    command: tool.command,
                    args: tool.args ?? []
                ))
            }
        }
        cached = true
    }

    public func plugins() -> [String: PluginManifest] { manifests }
    public func toolNames() -> [String] { toolCache.map { $0.name } }
    public func tools() -> [PluginTool] { toolCache }
    public func llm() -> PluginManifest.LLM? { manifests.values.compactMap { $0.llm }.first }
}

// MARK: - Mutable registry (compile-time registry + plugin tools at runtime)

/// The runtime layer on top of the compile-time registry: plugin tools sit
/// beside the built-ins without touching them (Hermes bundles non-core tools
/// at runtime). `lookup` prefers built-ins, then plugins.
public actor MutableToolRegistry {
    public let builtIn: CompileTimeToolRegistry
    private var pluginEntries: [String: ToolEntry] = [:]

    public init(builtIn: CompileTimeToolRegistry) {
        self.builtIn = builtIn
    }

    public func install(pluginTool: PluginTool) {
        let entry = ToolEntry(
            name: pluginTool.name,
            toolset: "plugins",
            description: pluginTool.description,
            schema: .object(properties: [
                "args": .object(properties: [:]),
            ]),
            handler: { args in
                var result = ""
                do {
                    result = try await pluginTool.invoke(args: args)
                } catch {
                    result = "Error: plugin tool failed: \(error.localizedDescription)"
                }
                return result
            },
            emoji: "🧩"
        )
        pluginEntries[pluginTool.name] = entry
    }

    public func lookup(name: String) -> ToolEntry? {
        builtIn.lookup(name: name) ?? pluginEntries[name]
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
    /// plugins (Hermes agent_init plugin toolset bundling).
    public static func make(pluginRegistry: PluginRegistry? = nil) async throws -> MutableToolRegistry {
        let builtIn = try ArcAgentCore.buildDefaultRegistry()
        let registry = MutableToolRegistry(builtIn: builtIn)
        let plugins = pluginRegistry ?? PluginRegistry.shared
        try? await plugins.loadAll()
        for tool in await plugins.tools() {
            await registry.install(pluginTool: tool)
        }
        return registry
    }
}
