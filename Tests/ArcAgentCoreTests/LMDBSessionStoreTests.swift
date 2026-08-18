import Testing
@testable import ArcAgentCore
import Foundation

// =========================================================================
// MARK: - LMDB Session Store Tests
// =========================================================================

/// Helper to open an LMDB environment in a temp directory.
func openTestEnv(_ path: String) throws -> OpaquePointer {
    try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: path),
        withIntermediateDirectories: true
    )
    let filePath = path + "/session.mdb"
    print("Opening LMDB env at: \(filePath)")
    return try LMDB.envOpen(path: filePath, mapSize: 10 * 1024 * 1024, maxReaders: 4, maxDBs: 8)
}

@Test("LMDBSessionStore create and read back")
func sessionStoreCreateAndRead() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("lmdb-test-\(UUID().uuidString)")
    let sessionID = UUID().uuidString
    let env = try openTestEnv(tmp.path + "/" + sessionID)
    defer { LMDB.envClose(env) }

    let store = LMDBSessionStore(env: env)

    let session = Session(
        id: sessionID,
        model: "test-model",
        provider: "test-provider",
        messages: [
            Message(role: .user, content: "Hello"),
            Message(role: .assistant, content: "Hi there!")
        ]
    )

    try store.createSync(session)

    let loaded = try await store.get(id: sessionID)
    #expect(loaded != nil)
    #expect(loaded?.id == sessionID)
    #expect(loaded?.messages.count == 2)
    #expect(loaded?.messages[0].content == "Hello")
    #expect(loaded?.messages[1].content == "Hi there!")

    try? FileManager.default.removeItem(at: tmp)
}

@Test("LMDBSessionStore appendMessage")
func sessionStoreAppend() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("lmdb-test-\(UUID().uuidString)")
    let sessionID = UUID().uuidString
    let env = try openTestEnv(tmp.path + "/" + sessionID)
    defer { LMDB.envClose(env) }

    let store = LMDBSessionStore(env: env)

    let session = Session(
        id: sessionID,
        model: "test-model",
        provider: "test-provider",
        messages: [
            Message(role: .user, content: "Hello")
        ]
    )

    try await store.create(session)
    try await store.appendMessage(sessionID: sessionID, message: Message(role: .assistant, content: "World"))

    let loaded = try await store.get(id: sessionID)
    #expect(loaded?.messages.count == 2)
    #expect(loaded?.messages[1].content == "World")

    try? FileManager.default.removeItem(at: tmp)
}

@Test("LMDBSessionStore update")
func sessionStoreUpdate() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("lmdb-test-\(UUID().uuidString)")
    let sessionID = UUID().uuidString
    let env = try openTestEnv(tmp.path + "/" + sessionID)
    defer { LMDB.envClose(env) }

    let store = LMDBSessionStore(env: env)

    var session = Session(
        id: sessionID,
        model: "test-model",
        provider: "test-provider",
        messages: [
            Message(role: .user, content: "Hello")
        ]
    )

    try await store.create(session)
    session.messages.append(Message(role: .assistant, content: "World"))
    try await store.update(session)

    let loaded = try await store.get(id: sessionID)
    #expect(loaded?.messages.count == 2)
    #expect(loaded?.messages[1].content == "World")

    try? FileManager.default.removeItem(at: tmp)
}

@Test("LMDBSessionStore delete")
func sessionStoreDelete() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("lmdb-test-\(UUID().uuidString)")
    let sessionID = UUID().uuidString
    let env = try openTestEnv(tmp.path + "/" + sessionID)
    defer { LMDB.envClose(env) }

    let store = LMDBSessionStore(env: env)

    let session = Session(
        id: sessionID,
        model: "test-model",
        provider: "test-provider",
        messages: []
    )

    try await store.create(session)
    try await store.delete(id: sessionID)

    let loaded = try await store.get(id: sessionID)
    #expect(loaded == nil)

    try? FileManager.default.removeItem(at: tmp)
}

@Test("LMDBSessionStore get nonexistent returns nil")
func sessionStoreGetNonexistent() async throws {
    let store = LMDBSessionStore()
    let loaded = try await store.get(id: "nonexistent-session")
    #expect(loaded == nil)
}
