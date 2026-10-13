import Testing
@testable import ArcAgentCore
import Foundation

/// Profile isolation + distribution tests (reference `profiles.py` /
/// `profile_distribution.py` parity).
@Suite("Profile distributions", .serialized)
struct ProfileDistributionTests {

    /// Run `body` against an isolated temporary profile root and restore.
    private func withTempRoot(_ body: () async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-profile-tests-\(UUID().uuidString)", isDirectory: true)
        ProfileManager.testProfilesRoot = root.path
        defer {
            ProfileManager.testProfilesRoot = nil
            try? FileManager.default.removeItem(at: root)
        }
        try await body()
    }

    @Test("create persists profiles/<name>/config.json in the profile dir")
    func createWritesConfig() async throws {
        try await withTempRoot {
            let manager = ProfileManager()
            var p = try await manager.create(name: "prod")
            p.title = "Prod Profile"
            p.model = "gpt-5"
            try await manager.update(p)

            let configURL = URL(fileURLWithPath: ProfileManager.configPath(for: "prod"))
            #expect(FileManager.default.fileExists(atPath: configURL.path))
            let decoded = try JSONDecoder().decode(Profile.self, from: Data(contentsOf: configURL))
            #expect(decoded.title == "Prod Profile")
            #expect(decoded.model == "gpt-5")
        }
    }

    @Test("export → delete → import round-trips the profile record")
    func exportImportRoundTrip() async throws {
        try await withTempRoot {
            let manager = ProfileManager()
            var p = try await manager.create(name: "prod")
            p.title = "Prod Profile"
            p.model = "gpt-5"
            p.provider = "anthropic"
            p.enabledToolsets = ["file", "terminal"]
            try await manager.update(p)

            let archive = URL(fileURLWithPath: ProfileManager.profilesDir)
                .appendingPathComponent("prod-distribution.zip")
            let out = try await manager.export(name: "prod", to: archive)
            #expect(FileManager.default.fileExists(atPath: out.path))

            try await manager.delete(name: "prod")
            #expect(try await manager.get(name: "prod") == nil)

            let imported = try await manager.importDistribution(from: archive)
            #expect(imported == "prod")
            let loaded = try await manager.get(name: "prod")
            #expect(loaded != nil)
            #expect(loaded?.title == "Prod Profile")
            #expect(loaded?.model == "gpt-5")
            #expect(loaded?.provider == "anthropic")
            #expect(loaded?.enabledToolsets == ["file", "terminal"])
        }
    }

    @Test("export of a missing profile throws notFound")
    func exportMissing() async throws {
        try await withTempRoot {
            let manager = ProfileManager()
            let archive = URL(fileURLWithPath: ProfileManager.profilesDir).appendingPathComponent("nope.zip")
            do {
                _ = try await manager.export(name: "nope", to: archive)
                Issue.record("expected notFound")
            } catch let e as ProfileError {
                #expect(e == .notFound("nope"))
            }
        }
    }

    @Test("profile dir helpers point inside the profile root")
    func dirHelpers() {
        let base = "/tmp/fake-arc-root"
        ProfileManager.testProfilesRoot = base
        defer { ProfileManager.testProfilesRoot = nil }
        #expect(ProfileManager.configPath(for: "p") == "\(base)/p/config.json")
        #expect(ProfileManager.skillsURL(for: "p")?.path == "\(base)/p/skills")
    }
}
