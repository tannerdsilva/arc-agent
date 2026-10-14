import Foundation
import Testing
@testable import ArcAgentCore

/// Task 1 — a shared session pins its full model/config so every contributor
/// runs the same prompt config (cache warmth). The snapshot must survive both
/// the `Session` JSON round-trip (file store) and the `TesseraSessionMeta`
/// encode/decode (tessera store).
@Suite("Session config persistence")
struct SessionConfigPersistenceTests {

    private let snapshot = SessionConfigSnapshot(
        model: "gpt-4o",
        provider: "openai",
        moa: MoAConfig(enabled: true, degradedReferencePolicy: "loud",
                       maxConcurrentReferences: 2, toolResultBudgetChars: 1000),
        contextLength: 128_000,
        reasoningEffort: "high",
        temperature: 0.7,
        topP: 0.9,
        maxOutputTokens: 4096,
        pinnedProfile: "analyst",
        thinkingLevel: "high"
    )

    @Test("Session round-trips the config snapshot through JSON")
    func sessionRoundTrips() throws {
        let s = Session(model: "gpt-4o", provider: "openai", title: "t", config: snapshot)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(Session.self, from: data)
        #expect(back.config?.model == "gpt-4o")
        #expect(back.config?.provider == "openai")
        #expect(back.config?.reasoningEffort == "high")
        #expect(back.config?.pinnedProfile == "analyst")
        #expect(back.config?.contextLength == 128_000)
        #expect(back.config?.temperature == 0.7)
        #expect(back.config?.topP == 0.9)
        #expect(back.config?.maxOutputTokens == 4096)
        #expect(back.config?.thinkingLevel == "high")
        #expect(back.config?.moa?.enabled == true)
    }

    @Test("TesseraSessionMeta round-trips the config snapshot")
    func metaRoundTrips() throws {
        let meta = TesseraSessionMeta(
            seq: 7, sessionID: "abc", createdAt: Date(), updatedAt: Date(),
            model: "gpt-4o", provider: "openai", messageCount: 0,
            totalTokens: 0, titleHint: "hi", config: snapshot
        )
        let data = try JSONEncoder().encode(meta)
        let back = try JSONDecoder().decode(TesseraSessionMeta.self, from: data)
        #expect(back.config?.model == "gpt-4o")
        #expect(back.config?.temperature == 0.7)
        #expect(back.config?.thinkingLevel == "high")
        #expect(back.config?.moa?.referenceModels.isEmpty == true)
    }

    @Test("nil config decodes as nil (legacy records)")
    func nilConfigDefaults() throws {
        let meta = TesseraSessionMeta(
            seq: 1, sessionID: "x", createdAt: Date(), updatedAt: Date(),
            model: "m", provider: "p", messageCount: 0, totalTokens: 0
        )
        let data = try JSONEncoder().encode(meta)
        let back = try JSONDecoder().decode(TesseraSessionMeta.self, from: data)
        #expect(back.config == nil)
        // A Session decoded without a config key must also default to nil.
        let sessionData = Data(#"{"id":"i","createdAt":0,"updatedAt":0,"model":"m","provider":"p"}"#.utf8)
        let sess = try JSONDecoder().decode(Session.self, from: sessionData)
        #expect(sess.config == nil)
    }
}
