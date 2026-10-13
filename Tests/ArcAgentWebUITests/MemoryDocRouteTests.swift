import Foundation
import Testing
import ArcAgentCore
@testable import ArcWebUI

/// The Memory panel must read/write the agent's *real* memory (through the
/// wired ``MemoryProvider`` and the profile's SOUL), not a web-UI-only copy
/// under `~/.arc-agent-webui/` that the running agent never reads.
@Suite("Memory doc routing")
struct MemoryDocRouteTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-memroute-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("memory routes through the wired MemoryProvider (agent memory), not a webui copy")
    func memoryWritesToProvider() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = FileMemoryProvider(directory: dir)

        let saved = await MemoryDocRoute.save("memory", content: "agent notes", memory: provider, profileName: nil)
        #expect(saved)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("MEMORY.md").path))
        #expect(try await provider.readMemory() == "agent notes")
        #expect(await MemoryDocRoute.load("memory", memory: provider, profileName: nil) == "agent notes")
    }

    @Test("user routes through the wired MemoryProvider")
    func userWritesToProvider() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = FileMemoryProvider(directory: dir)

        #expect(await MemoryDocRoute.save("user", content: "user profile", memory: provider, profileName: nil))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("USER.md").path))
        #expect(try await provider.readUser() == "user profile")
        #expect(await MemoryDocRoute.load("user", memory: provider, profileName: nil) == "user profile")
    }

    @Test("no provider -> empty load and failed save, never a webui-only copy")
    func nilProviderIsSafe() async {
        #expect(await MemoryDocRoute.load("memory", memory: nil, profileName: nil).isEmpty)
        #expect(!(await MemoryDocRoute.save("memory", content: "x", memory: nil, profileName: nil)))
        // The webui should never fall back to writing a copy anywhere.
        let webuiMem = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arc-agent-webui/MEMORY.md")
        #expect(!FileManager.default.fileExists(atPath: webuiMem.path))
    }

    /// The bug this test guards: Views / AppState+Actions must not reference
    /// a `~/.arc-agent-webui/` memory copy, and the panel must route through
    /// ``MemoryDocRoute``.
    @Test("webui no longer reads/writes memory docs under ~/.arc-agent-webui")
    func noWebuiMemoryCopyInCode() {
        let views = Self.source("Views.swift")
        let actions = Self.source("AppState+Actions.swift")
        #expect(!views.contains("appendingPathComponent(\".arc-agent-webui\").appendingPathComponent(name)"))
        #expect(actions.contains("MemoryDocRoute"))
        #expect(actions.contains("soulProfileName()"))
        // The provider-backed path must remain (memory/user route through it).
        #expect(!actions.contains("memoryFileURL"))
    }

    // Resolves a source file under the repo (mirrors the other webui suites).
    static func source(_ name: String) -> String {
        for base in ["Sources/ArcWebUI", "Sources/ArcAgentCore", "Sources/ArcAgentCore/Profile", "Sources/ArcAgentCore/Skills"] {
            if let s = try? String(contentsOfFile: "\(base)/\(name)") {
                return s
            }
        }
        return ""
    }
}
