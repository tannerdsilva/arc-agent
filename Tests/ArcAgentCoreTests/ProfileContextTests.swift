import Testing
import Foundation
@testable import ArcAgentCore

extension ArcCoreTestRoot {
    /// Model parameters live in the model configuration (per model); the
    /// profile carries identity, toolsets, and pinned skills only. Old stored
    /// profiles with a `context` key must still decode (unknown keys ignored),
    /// and contextSkills keep their round-trip.
    @Suite("Profile context removal", .serialized)
    struct ProfileContextConfigTests {

        @Test("a stored profile with a legacy context key decodes; parameters are ignored")
        func legacyContextKeyIgnored() throws {
            let json = """
            {
              "name": "legacy",
              "title": "",
              "description": "",
              "hasCustomKey": false,
              "isPinned": false,
              "createdAt": 0,
              "updatedAt": 0,
              "context": {
                "contextLength": 128000,
                "compressionBudget": 16000
              }
            }
            """
            let p = try JSONDecoder().decode(Profile.self, from: Data(json.utf8))
            #expect(p.contextSkills == nil)
        }

        @Test("a profile without context decodes back to nil (backward compatible)")
        func contextNilBackCompat() throws {
            let json = """
            {
              "name": "legacy",
              "title": "",
              "description": "",
              "hasCustomKey": false,
              "isPinned": false,
              "createdAt": 0,
              "updatedAt": 0
            }
            """
            let p = try JSONDecoder().decode(Profile.self, from: Data(json.utf8))
            #expect(p.contextSkills == nil)
        }

        @Test("contextSkills round-trip through Codable and keep order")
        func contextSkillsRoundTrip() throws {
            let p = Profile(name: "skillspinned", contextSkills: ["git-branch-recovery", "swift-testing-tests"])
            let data = try JSONEncoder().encode(p)
            let decoded = try JSONDecoder().decode(Profile.self, from: data)
            #expect(decoded.contextSkills == ["git-branch-recovery", "swift-testing-tests"])
        }
    }
}
