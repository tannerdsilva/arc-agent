import Crypto
import Foundation
import Testing
import ArcToolKit
@testable import ArcAgentCore

// MARK: - Tool surface inventory (T0 baseline)

extension ArcCoreTestRoot {
    @Suite("tool surface inventory")
    struct ToolSurfaceInventoryTests {

        @Test("the toolset universe is the declared one")
        func toolsetUniverse() throws {
            let actual = Set(try ArcAgentCore.testRegistry().allTools.map(\.toolset))
            // a tripwire, not a policy: adding a toolset is a decision, so it must
            // edit this line. T3 deletes this test once the type carries the decision.
            #expect(actual == [
                "browser", "code_execution", "computer_use", "core", "delegation", "file",
                "kanban", "mcp", "messaging", "profile", "project", "skills", "terminal",
                "todo", "tools", "web",
            ])
        }

        @Test("every built-in is compiled in")
        func origins() throws {
            let registry = try ArcAgentCore.testRegistry()
            #expect(registry.allTools.allSatisfy { $0.origin.isCompiledIn })
        }

        @Test("the tool array is name-sorted")
        func orderIsStable() throws {
            // FAILS TODAY — and only with a fixture plugin present. `testRegistry()`
            // alone is a `CompileTimeToolRegistry`, whose `allTools` sorts by name
            // (`CompileTimeToolRegistry.swift:83-87`), so without a plugin this test
            // passes green and proves nothing. The defect lives in the composite:
            // `MutableToolRegistry.allTools` appends the plugin tier in dictionary
            // order (`PluginRegistry.swift:497-499`), so `aaa_fixture` — which sorts
            // before every built-in — lands after them. T1 makes this pass.
            let (mutable, allInstalled) = try Self.fixtureRegistry()
            #expect(allInstalled)
            let names = mutable.allTools.map(\.name)
            #expect(names == names.sorted())
        }

        @Test("the schema baseline is pinned, not just recorded")
        func surfaceIsPinned() throws {
            // prints the two TOOL-SURFACE-BASELINE lines the shell script greps out
            // of three consecutive `swift test` runs: byte size and sha256 of the
            // per-turn prompt array. At T0 these were a record; as of T2 they are a
            // **pin** — the one renderer must reproduce the array byte for byte, and
            // any future change to these numbers is a declared delta (a schema, a
            // description, a tool, or the renderer drifting), never a re-baseline.
            // `toolSurfaceDigest` is a free function so the pin crosses files.
            let registry = try ArcAgentCore.testRegistry()
            let builtin = ToolSchemaRenderer.promptSchemas(
                registry: registry, disabled: [], config: ToolSearchConfig(), contextLength: 200_000)
            let builtinDigest = try toolSurfaceDigest(builtin)
            print("TOOL-SURFACE-BASELINE variant=builtin tools=\(registry.allTools.count) bytes=\(builtinDigest.bytes) sha=\(builtinDigest.sha)")
            #expect(builtinDigest.bytes == 29072)
            #expect(builtinDigest.sha == "c035d2233e4d6b9dd14494ae277b7b5ff1bb2bdd216e71f1bdd5d668a4935a2a")

            let (mutable, _) = try Self.fixtureRegistry()
            let withPlugin = ToolSchemaRenderer.promptSchemas(
                registry: mutable, disabled: [], config: ToolSearchConfig(), contextLength: 200_000)
            let pluginDigest = try toolSurfaceDigest(withPlugin)
            print("TOOL-SURFACE-BASELINE variant=plugin tools=\(mutable.allTools.count) bytes=\(pluginDigest.bytes) sha=\(pluginDigest.sha)")
            #expect(pluginDigest.bytes == 30098)
            #expect(pluginDigest.sha == "d57245df4216a0d01c7e86f545da288c5c6949d8fd4dc8a044162b45a6bc9ab7")
        }

        /// the composite the defect lives in: the sorted built-in registry with six
        /// fixture plugin tools admitted — enough dictionary entries that per-process
        /// iteration order has room to differ. The direct `PluginTool` constructor
        /// (the `PluggabilityTests.swift:326` shape) means no `~/.arc/plugins`
        /// directory is touched: the with-plugin case is reproducible on any machine.
        private static func fixtureRegistry() throws -> (MutableToolRegistry, Bool) {
            var mutable = MutableToolRegistry(builtIn: try ArcAgentCore.testRegistry())
            var allInstalled = true
            for letter in ["aaa", "bbb", "ccc", "ddd", "eee", "fff"] {
                let installed = mutable.install(pluginTool: PluginTool(
                    plugin: "audit", name: "\(letter)_fixture",
                    description: "audit fixture", command: "python3"))
                allInstalled = allInstalled && installed
            }
            return (mutable, allInstalled)
        }
    }
}

/// serialize a schema array and return its byte count and sha256 — the digest
/// every byte-stability claim in this program is pinned to. free function (not
/// a suite member) so T2's equivalence test reuses it across files.
func toolSurfaceDigest(_ schemas: [[String: Any]]) throws -> (bytes: Int, sha: String) {
    // `.sortedKeys` is load-bearing, not tidiness: swift's dictionary iteration
    // order is seeded per process, so plain JSONSerialization hands every process
    // a different key order and the sha measures the hasher, not the tool array.
    let data = try JSONSerialization.data(withJSONObject: schemas, options: [.sortedKeys])
    let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return (data.count, hex)
}
