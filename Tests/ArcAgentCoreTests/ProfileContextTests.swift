import Testing
import Foundation
@testable import ArcAgentCore

/// Per-profile context parameters (window size, generation budget, sampling)
/// must round-trip through Profile's Codable encoding, remain backward
/// compatible (nil context on old profiles), and correctly report overrides.
@Suite("ProfileContextConfig")
struct ProfileContextConfigTests {

    @Test("round-trips through Codable as part of Profile")
    func contextRoundTrip() throws {
        let ctx = ProfileContextConfig(
            contextLength: 128_000,
            maxOutputTokens: 4096,
            reasoningEffort: "high",
            temperature: 0.5,
            topP: 0.9,
            compressionBudget: 16_000
        )
        var p = Profile(name: "ctxsuite")
        p.context = ctx
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(Profile.self, from: data)
        #expect(decoded.context == ctx)
    }

    @Test("a profile without context decodes back to nil (backward compatible)")
    func contextNilBackCompat() throws {
        let p = Profile(name: "plain")
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(Profile.self, from: data)
        #expect(decoded.context == nil)
    }

    @Test("isEmpty is true only when no overrides are set")
    func isEmptyBehavior() {
        #expect(ProfileContextConfig().isEmpty)
        #expect(!ProfileContextConfig(contextLength: 64_000).isEmpty)
        #expect(!ProfileContextConfig(temperature: 0.7).isEmpty)
        #expect(!ProfileContextConfig(compressionBudget: 8_000).isEmpty)
    }

    @Test("partial config only overrides the set fields")
    func partialOverrides() {
        let ctx = ProfileContextConfig(contextLength: 32_768)
        #expect(ctx.contextLength == 32_768)
        #expect(ctx.maxOutputTokens == nil)
        #expect(ctx.reasoningEffort == nil)
        #expect(ctx.temperature == nil)
        #expect(ctx.topP == nil)
        #expect(ctx.compressionBudget == nil)
    }
}
