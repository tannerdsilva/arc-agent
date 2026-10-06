import ArgumentParser
import ArcAgentCore
import Foundation

// MARK: - Plugin Ops CLI (arc plugins)

/// `arc plugins` — inspect and exercise executable tool plugins.
///
/// Plugin installations live in `~/.arc/plugins/<name>/` as a `manifest.json`
/// plus an executable (or an interpreter+script pair); see docs/plugins.md.
struct PluginsCmd: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "plugins",
        abstract: "List and test executable tool plugins (~/.arc/plugins).",
        subcommands: [PluginsList.self, PluginsTest.self]
    )
}

/// `arc plugins list` — discovered plugins, their tools, and any
/// non-fatal discovery issues.
struct PluginsList: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List discovered tool plugins and their tools."
    )

    func run() async throws {
        let registry = PluginRegistry.shared
        do {
            try await registry.loadAll()
        } catch {
            print("❌ plugin discovery failed: \(error)")
            return
        }
        let manifests = await registry.plugins()
        let tools = await registry.tools()
        let issues = await registry.discoveryIssues()

        print("⚡ ARC Agent — Tool Plugins")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        if manifests.isEmpty {
            print("(no plugins found under ~/.arc/plugins/)")
        }
        for (name, manifest) in manifests.sorted(by: { $0.key < $1.key }) {
            let version = manifest.version.map { "v\($0)" } ?? "?"
            let description = manifest.description ?? "(no description)"
            print("🧩 \(name) — \(version)")
            print("   \(description)")
            print("   path: ~/.arc/plugins/\(name)")
            print("   tools:")
            for tool in manifest.tools {
                let entry = tool.entry.map { " + \($0)" } ?? ""
                print("     - \(tool.name) [\(tool.toolset ?? "plugins")] (\(tool.command)\(entry))")
                print("       \(tool.description)")
            }
            if let llm = manifest.llm {
                let baseURL = llm.baseURL.map { " (\($0))" } ?? ""
                print("   llm: \(llm.provider)/\(llm.model)\(baseURL)")
            }
            print("")
        }
        print("Total: \(manifests.count) plugin(s) — \(tools.count) tool(s)")
        if !issues.isEmpty {
            print("⚠️  Discovery issues:")
            for issue in issues {
                print("   - \(issue)")
            }
        }
    }
}

/// `arc plugins test <plugin> <tool> [json-args]` — run one plugin tool
/// directly (same path the agent uses) and print the result.
struct PluginsTest: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Run a plugin tool directly and print its result."
    )

    @Argument(help: "Plugin installation name (directory under ~/.arc/plugins/).")
    var plugin: String

    @Argument(help: "Tool name declared in the plugin's manifest.")
    var tool: String

    @Argument(help: "JSON object of arguments, e.g. {\"values\":[1,2]}.")
    var argsJSON: String = "{}"

    func run() async throws {
        let registry = PluginRegistry.shared
        do {
            try await registry.loadAll()
        } catch {
            print("❌ plugin discovery failed: \(error)")
            throw ExitCode.failure
        }
        let plugins = await registry.plugins()
        guard let manifest = plugins[plugin] else {
            print("❌ plugin '\(plugin)' not found (discovered: \(plugins.keys.sorted().joined(separator: ", ") ))")
            throw ExitCode.failure
        }
        guard let toolSpec = manifest.tools.first(where: { $0.name == tool }) else {
            print("❌ tool '\(tool)' not found in plugin '\(plugin)' (tools: \(manifest.tools.map { $0.name }.joined(separator: ", ")))")
            throw ExitCode.failure
        }
        let pluginTool = PluginTool(
            plugin: manifest.name,
            name: toolSpec.name,
            description: toolSpec.description,
            command: toolSpec.command,
            args: toolSpec.args ?? [],
            entry: toolSpec.entry,
            toolset: toolSpec.toolset ?? "plugins",
            requiresEnv: toolSpec.requiresEnv ?? [],
            schema: toolSpec.schema,
            cwdOverride: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".arc/plugins/\(plugin)", isDirectory: true)
        )
        let data = argsJSON.data(using: .utf8) ?? Data()
        let args: [String: Any]
        do {
            args = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        } catch {
            print("❌ args JSON unparsable: \(error)")
            throw ExitCode.failure
        }
        print("⚡ \(plugin)::\(tool) \(argsJSON)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        do {
            let result = try await pluginTool.invoke(args: args)
            print(result)
        } catch {
            print("❌ \(error)")
            throw ExitCode.failure
        }
    }
}
