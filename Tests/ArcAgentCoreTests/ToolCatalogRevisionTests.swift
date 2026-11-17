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
            let surface = ToolDependency<any ToolRegistry>(registry)
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
    }
}
