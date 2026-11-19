import Crypto
import Foundation
import Testing
import ArcToolKit
@testable import ArcAgentCore

// MARK: - Tool surface inventory (T0 baseline)

extension ArcCoreTestRoot {
    @Suite("tool surface inventory")
    struct ToolSurfaceInventoryTests {

        // `theToolsetUniverse` lived here: a 16-name tripwire that forced a
        // human edit whenever a toolset appeared. T3 replaced it with the type —
        // `ToolsetCatalogTests` pins all 19 catalog rows and `Toolset` has no
        // initializer that omits reach or disclosure, so the decision is the
        // compiler's now, not a test's.

        @Test("every built-in is compiled in")
        func origins() throws {
            let registry = try ArcAgentCore.testRegistry()
            #expect(registry.allTools.allSatisfy { $0.origin.isCompiledIn })
        }

        @Test("the tool array is name-sorted")
        func orderIsStable() throws {
            // The regression guard for F2/T1. It is red only with a fixture
            // plugin present: `testRegistry()` alone is a
            // `CompileTimeToolRegistry`, whose `allTools` already sorts
            // (`CompileTimeToolRegistry.swift:83-87`), so without a plugin this
            // would pass and prove nothing. The defect lived in the composite —
            // `MutableToolRegistry.allTools` used to append `pluginEntries.values`
            // in dictionary order, so `aaa_fixture`, which sorts before every
            // built-in, landed after them.
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
                registry: registry, enablement: ToolEnablementConfig(), config: ToolSearchConfig(), contextLength: 200_000)
            let builtinDigest = try toolSurfaceDigest(builtin)
            print("TOOL-SURFACE-BASELINE variant=builtin tools=\(registry.allTools.count) bytes=\(builtinDigest.bytes) sha=\(builtinDigest.sha)")
            #expect(builtinDigest.bytes == 28793)
            #expect(builtinDigest.sha == "aea708ecd83fba106655c5ead34abe0aa6d331bc84d245dab0f4fecfea2be620")

            let (mutable, _) = try Self.fixtureRegistry()
            let withPlugin = ToolSchemaRenderer.promptSchemas(
                registry: mutable, enablement: ToolEnablementConfig(), config: ToolSearchConfig(), contextLength: 200_000)
            let pluginDigest = try toolSurfaceDigest(withPlugin)
            print("TOOL-SURFACE-BASELINE variant=plugin tools=\(mutable.allTools.count) bytes=\(pluginDigest.bytes) sha=\(pluginDigest.sha)")
            #expect(pluginDigest.bytes == 29819)
            #expect(pluginDigest.sha == "d032227b558635a5ddce5f3ebef49a7429e6b1a7d66d578502d78e17d94ff245")
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
