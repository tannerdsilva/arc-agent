import Foundation
import Testing

@testable import ArcAgentCore
import MCP

extension ArcCoreTestRoot {
    /// The inward projection: a pack reached *through* a carrier becomes tools the
    /// agent loop can call, indistinguishable from built-ins. ``ArcToolDispatcher``
    /// goes the other way (registry → MCP); this is its inverse.
    @Suite("Tool source", .serialized)
    struct ToolSourceTests {

        /// A pack holding one internal tool: it mutates a field in a store whose
        /// key lives in the pack, so the model only ever names the field. That is
        /// the shape this rung exists for, and it deliberately carries no
        /// built-in's name — a pack adds capability, it does not shadow the
        /// registry.
        private func internalToolSource(toolset: String = "db") -> LocalPackToolSource {
            let entry = ToolEntry(
                name: "db_mutate",
                toolset: toolset,
                description: "Mutates a field in the encrypted store.",
                schema: .object(
                    properties: ["field": .string(description: "Field to mutate")],
                    required: ["field"]
                ),
                handler: { arguments in
                    let field: String = try ToolArguments.required(arguments, key: "field")
                    return "mutated \(field)"
                }
            )
            return LocalPackToolSource(
                toolset: toolset,
                dispatcher: ArcToolDispatcher(entries: [entry])
            )
        }

        /// A plugin registry over an empty directory, so a test never reads the
        /// machine's installed plugins.
        private func emptyPlugins() -> PluginRegistry {
            PluginRegistry(
                pluginsDir: FileManager.default.temporaryDirectory
                    .appendingPathComponent("arc-none-\(UUID().uuidString)", isDirectory: true)
            )
        }

        @Test("a local pack's tools arrive as ordinary agent tools")
        func localPackExposesItsTools() async throws {
            let source = internalToolSource(toolset: "db")
            let tools = try await source.tools()

            #expect(tools.map(\.name) == ["db_mutate"])
            let tool = try #require(tools.first)
            // The pack declares the toolset; the access roster decides reach.
            #expect(tool.toolset == "db")
            #expect(tool.description.isEmpty == false)

            await source.bridge.close()
        }

        @Test("the pack's wire schema becomes the agent tool's schema")
        func schemaTranslates() async throws {
            let source = internalToolSource()
            let tool = try #require(try await source.tools().first)

            let dictionary = tool.schema.asDictionary()
            #expect(dictionary["type"] as? String == "object")
            let properties = try #require(dictionary["properties"] as? [String: Any])
            #expect(properties.keys.contains("field"))

            await source.bridge.close()
        }

        @Test("the minted tool runs the pack in-process, with no child process")
        func runsInProcess() async throws {
            let source = internalToolSource()
            let tool = try #require(try await source.tools().first)

            #expect(try await tool.handler(["field": "email"]) == "mutated email")

            await source.bridge.close()
        }

        @Test("a pack failure reaches the model as an error, not as success text")
        func packFailureKeepsItsSignal() async throws {
            let source = internalToolSource()
            let tool = try #require(try await source.tools().first)

            // The pack throws for a missing argument. The framework folds a thrown
            // failure into an `isError` result rather than rethrowing it, so the
            // minted tool must carry the signal out in its text — a caller that
            // took the result's `content` raw would report this as a success.
            let result = try await tool.handler([:])
            #expect(result.hasPrefix("Error: "))

            await source.bridge.close()
        }

        @Test("the registry is itself a source")
        func registryIsASource() async throws {
            let registry = try ArcAgentCore.testRegistry()
            let tools = try await RegistryToolSource(registry: registry).tools()

            #expect(tools.count == registry.allTools.count)
            #expect(Set(tools.map(\.name)) == Set(registry.allTools.map(\.name)))
        }

        @Test("sources assemble into the registry the agent reads")
        func sourcesAssembleIntoTheRegistry() async throws {
            let source = internalToolSource(toolset: "db")
            let registry = try await ArcAgentCore.testMutableRegistry(
                pluginRegistry: emptyPlugins(),
                sources: [source]
            )

            #expect(registry.lookup(name: "db_mutate")?.toolset == "db")
            // The built-ins are still there, unchanged.
            #expect(registry.lookup(name: "read_file") != nil)

            await source.bridge.close()
        }

        @Test("two sources carrying one name are refused, not silently merged")
        func duplicateNamesAreRefused() async throws {
            let first = internalToolSource()
            let second = internalToolSource()

            await #expect(throws: ToolRegistryError.self) {
                _ = try await ArcAgentCore.testMutableRegistry(
                    pluginRegistry: emptyPlugins(),
                    sources: [first, second]
                )
            }

            await first.bridge.close()
            await second.bridge.close()
        }

        @Test("a pack advertising no parameters mints an empty parameter object")
        func shapelessPackMintsNoParameters() async throws {
            let entry = ToolEntry(
                name: "noop",
                toolset: "pack",
                description: "Takes nothing.",
                schema: .object(properties: [:]),
                handler: { _ in "ok" }
            )
            let source = LocalPackToolSource(
                toolset: "pack",
                dispatcher: ArcToolDispatcher(entries: [entry])
            )
            let tool = try #require(try await source.tools().first)

            let dictionary = tool.schema.asDictionary()
            #expect(dictionary["type"] as? String == "object")
            #expect((dictionary["properties"] as? [String: Any])?.isEmpty == true)
            #expect(try await tool.handler([:]) == "ok")

            await source.bridge.close()
        }
    }
}