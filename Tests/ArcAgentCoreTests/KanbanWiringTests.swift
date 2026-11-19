import Foundation
import Testing

@testable import ArcAgentCore

/// The kanban tool seam. The legacy five-tool family (`kanban_create`,
/// `kanban_list`, `kanban_show`, `kanban_complete`, `kanban_block`) was
/// replaced by one unified `kanban` tool with an `action` parameter —
/// everything kanban runs through it. These tests pin the new surface:
/// the tool is registered on every agent surface, and it works when a
/// store is injected (test isolation) exactly as it does through the
/// shared store selection in production.
@Suite("Kanban wiring")
struct KanbanWiringTests {

    private func call(
        _ registry: MutableToolRegistry, _ name: String, _ args: sending [String: Any] = [:]
    ) async throws -> String {
        let tool = try #require(registry.lookup(name: name)).tool
        return try await tool.handler(args)
    }

    /// The unified `kanban` tool is registered on a plain agent surface —
    /// no board slot, no special builder parameter.
    @Test("the unified kanban tool is registered on every surface")
    func unifiedToolRegistered() async throws {
        let registry = try await MutableToolRegistry.make(
            context: ArcAgentCore.testContext(),
            profiles: TesseraProfileStore.shared,
            memory: FileMemoryProvider(),
            sessions: FileSessionStore()
        )
        #expect(registry.lookup(name: "kanban") != nil)
        // The legacy per-verb family is gone — its names must not come back.
        #expect(registry.lookup(name: "kanban_create") == nil)
        #expect(registry.lookup(name: "kanban_list") == nil)
        #expect(registry.lookup(name: "kanban_show") == nil)
        #expect(registry.lookup(name: "kanban_complete") == nil)
        #expect(registry.lookup(name: "kanban_block") == nil)
    }

    /// The tool refuses unknown actions legibly (schema is action-keyed).
    @Test("unknown action answers with the action list")
    func unknownActionLegible() async throws {
        let entry = KanbanTool.entry()
        let out = try await entry.handler(["action": "teleport"])
        #expect(out.contains("unknown action"))
        #expect(out.contains("create"))
    }

    /// The refusal contract from D22 survives in spirit: a store-backed
    /// entry answers honestly rather than crashing on a missing store.
    @Test("store-backed entry round-trips a create")
    func injectedStoreRoundTrip() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kanban-wiring-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let entry = KanbanTool.entry(storeOverride: FileCardStore(arcHome: tmp))
        let created = try await entry.handler(["action": "create", "title": "wire the unified tool"])
        #expect(created.hasPrefix("Created task"))
        let listed = try await entry.handler(["action": "list"])
        #expect(listed.contains("wire the unified tool"))
    }
}
