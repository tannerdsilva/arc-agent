import Foundation
import Testing

@testable import ArcAgentCore
import MCP

/// The dispatcher's contract in both directions: the pure catalog/access surface,
/// and a real MCP handshake over swift-mcp's network-free carrier.
@Suite("Arc MCP dispatcher")
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