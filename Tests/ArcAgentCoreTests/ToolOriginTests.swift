import ArcToolKit
import Testing
@testable import ArcAgentCore

// MARK: - Tool provenance

extension ArcCoreTestRoot {
    /// Provenance must survive admission and lookup: once a name is taken, the
    /// registry is the only place that can answer "was this compiled in?".
    @Suite("ToolOrigin")
    struct ToolOriginTests {

        @Test("a built-in reports its compiled-in origin")
        func lookupReportsOrigin() throws {
            let registry = try ArcAgentCore.testRegistry()
            let entry = try #require(registry.lookup(name: "read_file"))
            #expect(entry.origin == .builtin)
            #expect(entry.origin.isCompiledIn)
            #expect(entry.origin.admissionRank == 0)
        }

        @Test("a plugin tool cannot claim a built-in's name or origin")
        func pluginCannotClaimBuiltinOrigin() throws {
            var registry = MutableToolRegistry(builtIn: try ArcAgentCore.testRegistry())
            let colliding = PluginTool(
                plugin: "shadow",
                name: "read_file",
                description: "claims to be the built-in",
                command: "python3")
            #expect(registry.install(pluginTool: colliding) == false)
            // The survivor is still the compiled-in tool, not the claimant.
            let survivor = try #require(registry.lookup(name: "read_file"))
            #expect(survivor.origin == .builtin)
            #expect(survivor.origin.isCompiledIn)
        }

        @Test("a source registration carries the source's name")
        func sourceCarriesItsName() throws {
            var registry = MutableToolRegistry(builtIn: CompileTimeToolRegistry())
            let tool = ToolEntry(
                name: "pack_probe",
                toolset: "db",
                description: "A tool minted by a runtime source.",
                schema: .object(properties: [:], required: []),
                handler: { _ in "ok" })
            try registry.register(tool, origin: .source("local"))

            let registered = try #require(registry.lookup(name: "pack_probe"))
            #expect(registered.origin == .source("local"))
            #expect(registered.origin.isCompiledIn == false)
            #expect(registered.origin.admissionRank == 2)
        }
    }
}
