import Foundation
import Testing
import ArcToolKit
@testable import ArcAgentCore

// MARK: - The served catalog follows the surface it was handed (T5d)

extension ArcCoreTestRoot {
    @Suite("Tool catalog revision")
    struct ToolCatalogRevisionTests {

        @Test("a tool admitted after construction is served by the live surface")
        func catalogFollowsTheSlot() throws {
            var registry = MutableToolRegistry(builtIn: try ArcAgentCore.testRegistry())
            let surface = ToolDependency<any ToolCatalogReader>(registry)
            let dispatcher = ArcToolDispatcher(surface: surface)

            #expect(dispatcher.toolCatalog(for: .root).contains { $0.name == "late_fixture" } == false)

            let before = registry.revision
            // hoisted out of `#expect`: the macro captures its argument as an
            // immutable `$0`, and `install` is `mutating`.
            let installed = registry.install(pluginTool: fixturePlugin("late_fixture"))
            #expect(installed)
            #expect(registry.revision > before)

            surface.set(registry)
            #expect(dispatcher.toolCatalog(for: .root).contains { $0.name == "late_fixture" })
            #expect(dispatcher.requiredAccess(named: "late_fixture") != nil)
        }

        @Test("a refused admission does not move the revision")
        func refusedAdmissionKeepsIdentity() throws {
            var registry = MutableToolRegistry(builtIn: try ArcAgentCore.testRegistry())
            let before = registry.revision
            let colliding = PluginTool(
                plugin: "shadow", name: "read_file",
                description: "claims a built-in", command: "python3")
            let refused = registry.install(pluginTool: colliding)
            #expect(refused == false)
            #expect(registry.revision == before)
            #expect(try ArcAgentCore.testRegistry().revision == 0)
        }

        @Test("every accepted mutation moves the identity, every refusal does not")
        func everyMutationSiteIsPinned() throws {
            // `revision` is the key T2's renderer cache invalidates on, so each
            // bump site and each refusal path is pinned here: an accepted
            // mutation that forgets to bump serves stale schemas forever, and a
            // refusal that bumps throws the cache away for nothing.
            var registry = MutableToolRegistry(builtIn: try ArcAgentCore.testRegistry())
            let start = registry.revision

            // register(origin:) — an accepted registration is a new surface.
            let direct = fixturePlugin("registered_fixture")
            try registry.register(direct, origin: .plugin("audit"))
            #expect(registry.revision == start + 1)

            // a duplicate registration throws and leaves the identity alone.
            var threw = false
            do { try registry.register(direct, origin: .plugin("audit")) } catch { threw = true }
            #expect(threw)
            #expect(registry.revision == start + 1)

            // install(pluginTool:) — an unmet `requires_env` is not a mutation:
            // the tool disappeared and the surface is byte-identical.
            let gated = PluginTool(
                plugin: "audit", name: "gated_fixture",
                description: "needs a variable nothing sets",
                command: "python3", requiresEnv: ["ARC_T5D_TEST_UNSET_VARIABLE_9F3A"])
            let refused = registry.install(pluginTool: gated)
            #expect(refused == false)
            #expect(registry.revision == start + 1)

            // replacingBuiltIns(_:) — the copy is a new surface, the original is not.
            let replaced = registry.replacingBuiltIns([])
            #expect(replaced.revision == start + 2)
            #expect(registry.revision == start + 1)
        }

        @Test("tool_search sees the plugins on the surface `make` produced")
        func toolSearchSeesTheSurfacesPlugins() async throws {
            // A plugin registry over a temp directory, never `~/.arc/plugins`:
            // the manifest is the fixture shape `PluggabilityTests` writes, and
            // `fixturePlugin` owns the tool's identity inside it.
            let fixture = fixturePlugin("late_arrival")
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("plugins-\(UUID().uuidString)")
            let pluginDir = root.appendingPathComponent(fixture.plugin)
            try FileManager.default.createDirectory(
                at: pluginDir, withIntermediateDirectories: true)
            let manifest: [String: Any] = [
                "name": fixture.plugin,
                "version": "1.0.0",
                "tools": [[
                    "name": fixture.name,
                    "description": fixture.description,
                    "command": fixture.command,
                ]],
            ]
            try JSONSerialization.data(withJSONObject: manifest)
                .write(to: pluginDir.appendingPathComponent("manifest.json"))

            let registry = try await MutableToolRegistry.make(
                context: ArcAgentCore.testContext(),
                profiles: TesseraProfileStore.shared,
                memory: FileMemoryProvider(),
                sessions: FileSessionStore(),
                pluginRegistry: PluginRegistry(pluginsDir: root)
            )
            // The plugin is on the returned surface, so a `tool_search` that
            // reads the slot must find it. The build-time fill names the
            // builder's own product — the copy `make` started from, which has no
            // plugins on it — so this is the assertion that `make` re-fills the
            // slot with the surface it is about to return.
            #expect(registry.lookup(name: "late_arrival") != nil)

            let out = try await registry.lookup(name: "tool_search")!.handler(
                ["query": "late_arrival", "form": "names"])
            // exact, not `contains`: the no-match line is
            // "No tools match 'late_arrival'." — it echoes the query, so a
            // substring assertion would pass on an empty catalog.
            #expect(out == "late_arrival")
        }
    }
}
