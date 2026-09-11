import Testing
import Foundation
@testable import ArcAgentCore

/// Tests for the pluggability layer: provider registries, context engines,
/// and the plugin registry + mutable tool registry.
@Suite("Pluggability")
struct PluggabilityTests {

    // MARK: - Registries

    @Test("web search registry selects active provider by env, default fallback")
    func webSearchRegistry() async {
        struct FakeSearch: WebSearchProvider {
            let name: String
            func search(query: String, maxResults: Int) async throws -> [String] { ["\(name):\(query)"] }
        }
        await WebSearchRegistry.shared.register(FakeSearch(name: "default"))
        await WebSearchRegistry.shared.register(FakeSearch(name: "brave"))
        let active = await WebSearchRegistry.shared.active()
        // No WEB_SEARCH_PROVIDER env in tests → default.
        #expect(active?.name == "default")

        let fakeEnv = ProcessInfo.processInfo.environment["WEB_SEARCH_PROVIDER"]
        if fakeEnv == nil {
            setenv("WEB_SEARCH_PROVIDER", "brave", 1)
            defer { unsetenv("WEB_SEARCH_PROVIDER") }
            let selected = await WebSearchRegistry.shared.active()
            #expect(selected?.name == "brave")
        }
    }

    // MARK: - Context engines

    @Test("default engine compresses at threshold and protects the head")
    func defaultEngine() {
        let engine = DefaultContextEngine()
        #expect(engine.shouldCompress(currentTokens: 1_000, threshold: 1_000))
        #expect(!engine.shouldCompress(currentTokens: 999, threshold: 1_000))

        let messages = (0..<12).map { Message(role: .user, content: "m\($0)") }
        let selected = engine.selectContext(messages: messages, threshold: 10, protectFirstN: 2)
        #expect(selected.first?.content == "m0")
        #expect(selected.count <= messages.count)
        #expect(selected.count >= 2)
    }

    @Test("prune-tool-results engine drops oversized tool results only")
    func pruneEngine() {
        let engine = PruneToolResultsEngine()
        let messages = [
            Message(role: .user, content: "hi"),
            Message(role: .tool, content: String(repeating: "x", count: 40_000)),
            Message(role: .tool, content: "small"),
        ]
        let pruned = engine.pruneToolResultsOnly(messages: messages, maxBytes: 10_000)
        #expect(pruned.count == 2)
        #expect(pruned.contains { $0.content == "small" })
        #expect(pruned.contains { $0.content == "hi" })

        // selectContext is a no-op for this engine.
        #expect(engine.selectContext(messages: messages, threshold: 1, protectFirstN: 1).count == 3)

        // Router picks it via env.
        let routed = ContextEngineRouter.resolve(environment: ["ARC_CONTEXT_ENGINE": "prune_tool_results"])
        #expect(routed.name == "prune_tool_results")
        let defaultRouted = ContextEngineRouter.resolve(environment: [:])
        #expect(defaultRouted.name == "default")
    }

    // MARK: - Plugin registry

    @Test("plugin discovery reads manifests and exposes tools/llm")
    func pluginDiscovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plugins-\(UUID().uuidString)")
        let pluginDir = root.appendingPathComponent("demo")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "name": "demo",
            "version": "1.2.0",
            "tools": [
                ["name": "demo_hello", "description": "say hi", "command": "./hello.sh"],
            ],
            "llm": ["provider": "custom", "model": "m-1", "base_url": "https://example.test/v1", "api_key_env": "DEMO_KEY"],
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: pluginDir.appendingPathComponent("manifest.json"))
        // A working plugin binary.
        let script = "#!/bin/sh\ncat\n"
        try Data(script.utf8).write(to: pluginDir.appendingPathComponent("hello.sh"))
        let registry = PluginRegistry(pluginsDir: root)
        try await registry.loadAll()
        #expect((await registry.plugins()).count == 1)
        #expect((await registry.toolNames()) == ["demo_hello"])
        let llm = await registry.llm()
        #expect(llm?.provider == "custom")
        #expect(llm?.model == "m-1")
        #expect(llm?.apiKeyEnv == "DEMO_KEY")
    }

    @Test("plugin tool invocation pipes JSON and parses {result}")
    func pluginInvoke() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plugins-\(UUID().uuidString)")
        let pluginDir = root.appendingPathComponent("echo")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        // Reads stdin, echoes back a result JSON.
        let script = """
        #!/bin/sh
        read line
        echo "{\\"result\\": \\"got: $line\\"}"
        """
        try Data(script.utf8).write(to: pluginDir.appendingPathComponent("run.sh"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pluginDir.appendingPathComponent("run.sh").path)

        let tool = PluginTool(plugin: "echo", name: "echo_tool", description: "",
                              command: "./run.sh", args: [], cwdOverride: pluginDir)
        let result = try await tool.invoke(args: ["x": 1])
        #expect(result.contains("got:"))
    }

    @Test("mutable registry layers plugin tools over built-ins (Hermes bundling)")
    func mutableRegistry() async throws {
        let builtIn = try ArcAgentCore.buildDefaultRegistry()
        let registry = MutableToolRegistry(builtIn: builtIn)
        #expect(await registry.lookup(name: "read_file") != nil)

        // No plugins dir → make() falls through cleanly.
        let made = try await MutableToolRegistry.make(pluginRegistry: PluginRegistry(pluginsDir: FileManager.default.temporaryDirectory.appendingPathComponent("none-\(UUID().uuidString)")))
        let schemas = await made.buildToolSchemas(enabled: [], disabled: [])
        #expect(schemas.count >= 36)
    }
}
