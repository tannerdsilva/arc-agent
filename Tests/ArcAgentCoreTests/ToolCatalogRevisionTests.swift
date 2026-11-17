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
    }
}
