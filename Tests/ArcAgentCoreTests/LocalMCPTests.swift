import Foundation
import Testing

@testable import ArcAgentCore
import MCP

/// The in-process carrier: arc's agent reaching arc's own tools over the MCP
/// wire, with no process, pipe or socket.
@Suite("Local MCP bridge")
struct LocalMCPTests {

    private func makeTempFile() throws -> (dir: URL, file: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-localmcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("bridge.txt")
        try "reached through the local carrier\n".write(to: file, atomically: true, encoding: .utf8)
        return (dir, file)
    }

    /// The `--args` payload a caller would hand the CLI.
    private func json(for object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try #require(String(data: data, encoding: .utf8))
    }

    @Test("the bridge sees every registered tool")
    func seesEveryTool() async throws {
        let registry = try ArcAgentCore.buildDefaultRegistry()
        let bridge = LocalMCPBridge(registry: registry)

        let tools = try await bridge.tools()
        #expect(tools.count == registry.allTools.count)
        #expect(Set(tools.map(\.name)) == Set(registry.allTools.map(\.name)))

        await bridge.close()
    }

    @Test("a native tool answers through the bridge")
    func callsANativeTool() async throws {
        let (dir, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bridge = LocalMCPBridge(registry: try ArcAgentCore.buildDefaultRegistry())
        let result = try await bridge.call(
            "read_file",
            argumentsJSON: try json(for: ["path": file.path])
        )

        #expect(result.isError == false)
        #expect(result.text.contains("reached through the local carrier"))

        await bridge.close()
    }

    @Test("a typed caller can reach the same client with a literal")
    func typedCallPath() async throws {
        let (dir, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bridge = LocalMCPBridge(registry: try ArcAgentCore.buildDefaultRegistry())
        _ = try await bridge.tools()
        let result = try await bridge.client.callTool("read_file", arguments: ["path": file.path])

        #expect(result.text.contains("reached through the local carrier"))

        await bridge.close()
    }

    @Test("the session is connected once and reused across calls")
    func reusesOneSession() async throws {
        let (dir, file) = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bridge = LocalMCPBridge(registry: try ArcAgentCore.buildDefaultRegistry())
        let arguments = try json(for: ["path": file.path])

        // `MCPClient.connect()` is not idempotent, so a second connection would
        // throw here if the bridge re-connected per invocation.
        for _ in 0..<3 {
            let result = try await bridge.call("read_file", argumentsJSON: arguments)
            #expect(result.text.contains("reached through the local carrier"))
        }

        await bridge.close()
    }

    @Test("an unserved tool is refused, not silently empty")
    func refusesUnknownTool() async throws {
        let bridge = LocalMCPBridge(registry: try ArcAgentCore.buildDefaultRegistry())

        await #expect(throws: (any Error).self) {
            _ = try await bridge.call("no_such_tool")
        }

        await bridge.close()
    }

    @Test("an argument payload that is not a JSON object is reported before the wire")
    func rejectsNonObjectArguments() async throws {
        let bridge = LocalMCPBridge(registry: try ArcAgentCore.buildDefaultRegistry())

        await #expect(throws: LocalMCPError.self) {
            _ = try await bridge.call("read_file", argumentsJSON: "[1, 2, 3]")
        }

        await bridge.close()
    }
}