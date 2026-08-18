import Testing
@testable import ArcAgentCore
import Foundation
import CLMDB

// =========================================================================
// MARK: - LMDB Memory Provider Tests
//
// These tests reproduce the gateway crash where readMemory() threw
// "LMDB error 13: Permission denied" on the first chat message.
// Root cause: read() opened a read-only transaction and called
// dbiOpen(create: true) — LMDB forbids creating a named DB inside an
// RO transaction and returns EACCES. The fix uses create: false and
// treats MDB_NOTFOUND as "no memory yet" (empty string).
// =========================================================================

/// Open a fresh LMDB environment in a temp directory, mimicking the
/// global env (~/.arc/global) with NO databases created yet.
private func openFreshGlobalEnv() throws -> (OpaquePointer, String) {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("lmdb-global-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    let env = try LMDB.envOpen(path: tmp, mapSize: 10 * 1024 * 1024, maxReaders: 4, maxDBs: 8, flags: 0)
    return (env, tmp)
}

@Test("readMemory on a fresh global env without a memory DB returns empty string")
func readMemoryFreshEnvNoDB() async throws {
    let (env, tmp) = try openFreshGlobalEnv()
    defer {
        LMDB.envClose(env)
        try? FileManager.default.removeItem(atPath: tmp)
    }

    // The global env exists on disk but the "memory" DB has never been
    // created. This is exactly the state of ~/.arc/global on a first
    // chat message. readMemory() must NOT throw EACCES.
    let provider = LMDBMemoryProvider(globalEnv: env)
    let content = try await provider.readMemory()
    #expect(content.isEmpty)
}

@Test("readUser on a fresh global env without a memory DB returns empty string")
func readUserFreshEnvNoDB() async throws {
    let (env, tmp) = try openFreshGlobalEnv()
    defer {
        LMDB.envClose(env)
        try? FileManager.default.removeItem(atPath: tmp)
    }

    let provider = LMDBMemoryProvider(globalEnv: env)
    let content = try await provider.readUser()
    #expect(content.isEmpty)
}

@Test("memory append then read roundtrip in global env")
func lmdbMemoryAppendAndRead() async throws {
    let (env, tmp) = try openFreshGlobalEnv()
    defer {
        LMDB.envClose(env)
        try? FileManager.default.removeItem(atPath: tmp)
    }

    let provider = LMDBMemoryProvider(globalEnv: env)
    try await provider.appendMemory("line 1")
    try await provider.appendMemory("line 2")

    let content = try await provider.readMemory()
    #expect(content.contains("line 1"))
    #expect(content.contains("line 2"))
}

@Test("memory replace works in global env")
func lmdbMemoryReplace() async throws {
    let (env, tmp) = try openFreshGlobalEnv()
    defer {
        LMDB.envClose(env)
        try? FileManager.default.removeItem(atPath: tmp)
    }

    let provider = LMDBMemoryProvider(globalEnv: env)
    try await provider.writeMemory("alpha beta gamma")
    try await provider.replaceMemory(old: "beta", new: "BETA")

    let content = try await provider.readMemory()
    #expect(content == "alpha BETA gamma")
}
