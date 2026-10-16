import Foundation
import Testing

@testable import ArcAgentCore
import MCP

extension ArcCoreTestRoot {
    /// The dispatcher's contract in both directions: the pure catalog/access surface,
    /// and a real MCP handshake over swift-mcp's network-free carrier.
    @Suite("Arc MCP dispatcher", .serialized)
    struct ArcToolDispatcherTests {

        // MARK: - Catalog and schema

        @Test("the catalog is the registry, not a copy of it")
        func catalogMatchesRegistry() throws {
            let registry = try ArcAgentCore.buildDefaultRegistry()
            let dispatcher = ArcToolDispatcher(registry: registry)
            let served = Set(dispatcher.toolCatalog(for: .root).map(\.name))
            #expect(served == Set(registry.allTools.map(\.name)))
        }

        @Test("arc's hand-written schema reaches the wire as parameter metadata")
        func schemaReachesTheWire() throws {
            let dispatcher = ArcToolDispatcher(entries: [ReadFileTool.entry])
            let descriptor = try #require(dispatcher.toolCatalog(for: .root).first)

            #expect(descriptor.name == "read_file")
            #expect(descriptor.description.isEmpty == false)
            #expect(Set(descriptor.parameters.map(\.name)) == ["path", "offset", "limit"])

            let path = try #require(descriptor.parameters.first { $0.name == "path" })
            #expect(path.typeName == "String")
            #expect(path.description?.isEmpty == false)
            // Note: arc's schemas are declared as `.object(properties:)` with no
            // `required:` list, so nothing is advertised as mandatory on the wire
            // even where the handler enforces it (`read_file` rejects a missing
            // `path` at call time). See `translationsFollowTheSchema` for the
            // mechanism, which is faithful to whatever the schema declares.
            #expect(path.required == false)
        }

        @Test("required-ness, defaults and kinds translate as the schema declares them")
        func translationsFollowTheSchema() throws {
            let schema = JSONSchema.object(
                properties: [
                    "path": .string(description: "Path to the file to read"),
                    "limit": .integer(description: "Maximum number of lines to return", default: 2000),
                    "force": .boolean(description: "Overwrite the target"),
                ],
                required: ["path"]
            )
            let parameters = ArcToolDispatcher.parameters(from: schema)

            #expect(parameters.map(\.name) == ["force", "limit", "path"])

            let path = try #require(parameters.first { $0.name == "path" })
            #expect(path.required == true)
            #expect(path.kind == .argument)
            #expect(path.hasDefault == false)

            let limit = try #require(parameters.first { $0.name == "limit" })
            #expect(limit.required == false)
            #expect(limit.kind == .option)
            #expect(limit.hasDefault == true)
            #expect(limit.typeName == "Int")

            let force = try #require(parameters.first { $0.name == "force" })
            #expect(force.kind == .flag)
            #expect(force.typeName == "Bool")
        }

        // MARK: - Access policy

        @Test("the local process sees everything; a network caller sees nothing")
        func accessTiers() throws {
            let registry = try ArcAgentCore.buildDefaultRegistry()
            let dispatcher = ArcToolDispatcher(registry: registry)

            #expect(dispatcher.toolCatalog(for: .root).count == registry.allTools.count)
            // `.public` is deliberate emptiness: no arc toolset is exposed to an
            // unauthenticated network caller.
            #expect(dispatcher.toolCatalog(for: .public).isEmpty)
        }

        @Test("a loopback caller loses filesystem, shell, code-execution and desktop tools")
        func loopbackCallerLosesLocalOnlyToolsets() throws {
            let dispatcher = ArcToolDispatcher(registry: try ArcAgentCore.buildDefaultRegistry())
            let names = Set(dispatcher.toolCatalog(for: .admin).map(\.name))

            #expect(names.contains("web_search"))
            #expect(!names.contains("read_file"))
            #expect(!names.contains("write_file"))
            #expect(!names.contains("patch"))
            #expect(!names.contains("terminal"))
            #expect(!names.contains("execute_code"))

            #expect(dispatcher.requiredAccess(named: "terminal") == .root)
            #expect(dispatcher.requiredAccess(named: "web_search") == .admin)
            #expect(dispatcher.requiredAccess(named: "no_such_tool") == nil)
        }

        @Test("a toolset no roster names is denied to every socket caller")
        func undeclaredToolsetIsDenied() {
            // `db` is what a pack holding an encryption key declares. Nothing may
            // reach it over a socket until someone says so deliberately.
            let dispatcher = ArcToolDispatcher(entries: [
                ToolEntry(
                    name: "db_mutate",
                    toolset: "db",
                    description: "Mutates a field in the encrypted store.",
                    schema: .object(properties: ["field": .string(description: "Field")]),
                    handler: { _ in "ok" }
                )
            ])

            #expect(dispatcher.toolCatalog(for: .root).map(\.name) == ["db_mutate"])
            #expect(dispatcher.requiredAccess(named: "db_mutate") == .root)
            // Fails while the mapping's `else` branch hands every unnamed toolset
            // `.admin`: the local machine can then call a tool whose author never
            // made that decision.
            #expect(dispatcher.toolCatalog(for: .admin).isEmpty)
        }

        @Test("every built-in toolset has a declared access tier")
        func everyToolsetIsDeclared() throws {
            // The roster is only closed if something forces the decision when a
            // toolset appears. This is that mechanism, not the table.
            let declared = ArcToolDispatcher.inProcessOnlyToolsets
                .union(ArcToolDispatcher.localMachineToolsets)
            let actual = Set(try ArcAgentCore.buildDefaultRegistry().allTools.map(\.toolset))

            #expect(
                actual.subtracting(declared).isEmpty,
                "undeclared toolset(s): \(actual.subtracting(declared).sorted()) — declare deliberately"
            )
        }

        @Test("a plugin's claimed toolset can restrict reach but never expand it")
        func pluginToolsetClaimCannotExpandReach() {
            // A plugin owns this string; arc decides what it is worth.
            let claimsLocalOnly = PluginTool(
                plugin: "peer",
                name: "peer_shell",
                description: "Runs a command.",
                command: "true",
                toolset: "file"
            )
            let claimsAdmittedNamespace = PluginTool(
                plugin: "swift-package-utilitykit",
                name: "pkg_build",
                description: "Builds the package.",
                command: "true",
                toolset: "swift-package-utilitykit"
            )
            let dispatcher = ArcToolDispatcher(
                entries: [claimsLocalOnly, claimsAdmittedNamespace]
            )

            // A claim can restrict: declaring `file` keeps it in this process.
            #expect(dispatcher.requiredAccess(named: "peer_shell") == .root)
            // The roster grants reach; the claim cannot go beyond it.
            #expect(dispatcher.requiredAccess(named: "pkg_build") == .admin)
            #expect(dispatcher.toolCatalog(for: .admin).map(\.name) == ["pkg_build"])
        }

        @Test("a tool can be held below its toolset's tier")
        func placementTightensBelowToolsetTier() {
            // `web` is loopback-servable, so only the tool's own declaration can
            // hold it back.
            let held = ArcToolDispatcher(entries: [
                ToolEntry(
                    name: "db_mutate",
                    toolset: "web",
                    description: "Mutates a field in the encrypted store.",
                    schema: .object(properties: ["field": .string(description: "Field")]),
                    handler: { _ in "ok" },
                    placement: .inProcessOnly
                )
            ])

            #expect(held.requiredAccess(named: "db_mutate") == .root)
            #expect(held.toolCatalog(for: .root).map(\.name) == ["db_mutate"])
            #expect(held.toolCatalog(for: .admin).isEmpty)
            #expect(held.toolCatalog(for: .public).isEmpty)

            // Control: the same tool in the same toolset *without* the declaration
            // is served to loopback — so the placement is what holds it back, not
            // the toolset.
            let open = ArcToolDispatcher(entries: [
                ToolEntry(
                    name: "db_read",
                    toolset: "web",
                    description: "Reads a field from the encrypted store.",
                    schema: .object(properties: ["field": .string(description: "Field")]),
                    handler: { _ in "ok" }
                )
            ])
            #expect(open.toolCatalog(for: .admin).map(\.name) == ["db_read"])
        }

        @Test("an internal pack's tool stays in this process while its toolset is reachable")
        func internalPackStaysInProcess() async throws {
            // The pack holds the key; the model only ever names the field. Its
            // toolset (`web`) is loopback-servable, so the placement is the only
            // thing keeping it off the wire.
            let inner = ToolEntry(
                name: "db_mutate",
                toolset: "web",
                description: "Mutates a field in the encrypted store.",
                schema: .object(
                    properties: ["field": .string(description: "Field to mutate")],
                    required: ["field"]
                ),
                handler: { arguments in
                    let field: String = try ToolArguments.required(arguments, key: "field")
                    return "mutated \(field) [the key never left this process]"
                }
            )
            let source = LocalPackToolSource(
                toolset: "web",
                placement: .inProcessOnly,
                dispatcher: ArcToolDispatcher(entries: [inner])
            )

            // (a) the agent surface sees it, carrying the declaration
            let tool = try #require(try await source.tools().first)
            #expect(tool.placement == .inProcessOnly)
            #expect(tool.toolset == "web")

            // (b) the in-process carrier runs it
            let result = try await tool.handler(["field": "email"])
            #expect(result.contains("the key never left this process"))

            // (c) assembled into the registry the agent reads, and served outward:
            // absent from the loopback catalog while its own toolset's tools are
            // still there.
            var registry = MutableToolRegistry(builtIn: try ArcAgentCore.buildDefaultRegistry())
            try registry.register(tool)
            let outward = ArcToolDispatcher(registry: registry)

            let loopback = Set(outward.toolCatalog(for: .admin).map(\.name))
            #expect(!loopback.contains("db_mutate"))
            #expect(loopback.contains("web_search"))
            #expect(Set(outward.toolCatalog(for: .root).map(\.name)).contains("db_mutate"))

            // (d) the gate's input: a `.admin` caller is below what this tool
            // requires, which is what the server's gate refuses with `-32000`
            // (proven live for `terminal` in rung 2 — same gate, same mapping).
            #expect(outward.requiredAccess(named: "db_mutate") == .root)

            await source.bridge.close()
        }

        @Test("the roster admits every plugin namespace the machine actually has")
        func admittedPluginNamespacesCoverInstalledPlugins() async throws {
            // The measured half of the decision: the installed plugin's 25 tools
            // must stay reachable, because rung 2 was ratified on that basis.
            let tools = await PluginRegistry.shared.tools()
            let installed = Set(tools.map(\.toolset))

            #expect(
                installed.subtracting(ArcToolDispatcher.localMachineToolsets).isEmpty,
                "an installed plugin's toolset is unrostered: \(installed.subtracting(ArcToolDispatcher.localMachineToolsets).sorted())"
            )
        }

        // MARK: - Caller resolution

        @Test("loopback resolves to admin in the address shape the transport passes")
        func callerResolution() {
            // NIO's `SocketAddress.description`, which TCPTransport hands the resolver.
            #expect(ArcToolDispatcher.callerAccess(for: "[IPv4]127.0.0.1/127.0.0.1:54321") == .admin)
            #expect(ArcToolDispatcher.callerAccess(for: "[IPv6]::1/::1:54321") == .admin)
            #expect(ArcToolDispatcher.callerAccess(for: "127.0.0.1:54321") == .admin)
            // Not loopback: an address that merely contains "::1" must stay public.
            #expect(ArcToolDispatcher.callerAccess(for: "[IPv6]2001:db8::1/2001:db8::1:1234") == .public)
            #expect(ArcToolDispatcher.callerAccess(for: "[IPv4]10.0.0.5/10.0.0.5:1234") == .public)
        }

        // MARK: - The wire

        @Test("arc's native tools answer over the MCP wire, in-process")
        func inProcessRoundTrip() async throws {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-dispatcher-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let file = dir.appendingPathComponent("probe.txt")
            try "native file io, over mcp, no subprocess\n"
                .write(to: file, atomically: true, encoding: .utf8)

            let dispatcher = ArcToolDispatcher(entries: [ReadFileTool.entry, SearchFilesTool.entry])
            let client = MCPClient(
                transport: LocalClientTransport(
                    dispatcher: dispatcher,
                    configuration: .init(serverName: "arc-native", serverVersion: "0.1.0")
                )
            )
            try await client.connect()
            #expect(await client.negotiatedVersion() != nil)

            let tools = try await client.listTools()
            #expect(tools.map(\.name).sorted() == ["read_file", "search_files"])

            let result = try await client.callTool("read_file", arguments: ["path": file.path])
            let text = result.content.compactMap { block -> String? in
                if case .text(let value) = block { return value }
                return nil
            }.joined(separator: "\n")
            #expect(result.isError == false)
            #expect(text.contains("native file io, over mcp, no subprocess"))

            // An unserved tool is a JSON-RPC error, not an error-result.
            do {
                _ = try await client.callTool("pkg_targets", arguments: [:])
                Issue.record("an unknown tool must not resolve to a result")
            } catch {
                #expect(String(describing: error).contains("-32602"))
            }

            await client.close()
        }
    }
}