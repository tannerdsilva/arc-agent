import Foundation
import Testing

import ArcAgentCore
@testable import ArcWebUI

/// The five 2026-10-28 web UI bug fixes: insights "Skills Used" counts only
/// genuine invocations, `agent.max_turn_duration` defaults to unlimited and is
/// honored end-to-end, and the §-entry separator is display-only with an exact
/// round-trip through the editor.
@Suite("Bugfix regression 2026-10-28")
struct Bugfix20261028Tests {

    // MARK: § entry sections (view-layer only)

    @Test("splitSections splits on bare § lines and rejoins byte-exactly")
    func sectionRoundTrip() {
        let content = "first entry\nsecond line\n§\nsecond entry\n§\nthird"
        let sections = MemoryDocRoute.splitSections(content)
        #expect(sections.count == 3)
        #expect(sections[0] == "first entry\nsecond line")
        #expect(sections[1] == "second entry")
        #expect(sections[2] == "third")
        #expect(MemoryDocRoute.joinSections(sections) == content)
    }

    @Test("a § inside entry content is not a delimiter; whitespace-tolerant delimiter lines are")
    func delimiterPrecision() {
        let content = "entry with § mid-line stays whole\n§\nnext"
        let sections = MemoryDocRoute.splitSections(content)
        #expect(sections.count == 2)
        #expect(sections[0] == "entry with § mid-line stays whole")
        #expect(MemoryDocRoute.joinSections(sections) == "entry with § mid-line stays whole\n§\nnext")

        let padded = "a\n  §  \nb"
        #expect(MemoryDocRoute.splitSections(padded).count == 2)
    }

    @Test("empty bookend sections keep their delimiters; edges canonicalize to \\n§\\n")
    func emptyBookends() {
        let content = "§\nonly entry\n§"
        let sections = MemoryDocRoute.splitSections(content)
        #expect(sections.count == 3)
        #expect(sections[0].isEmpty && sections[2].isEmpty)
        // Malformed bookends (a file that starts/ends with a bare § line)
        // rejoin with the canonical "\n§\n" delimiter — both § separators are
        // preserved; only the edge newlines are canonicalized. Well-formed
        // files (delimiter strictly between entries) are byte-exact.
        let rejoined = MemoryDocRoute.joinSections(sections)
        #expect(rejoined == "\n§\nonly entry\n§\n")
        #expect(MemoryDocRoute.splitSections(rejoined) == sections)
    }

    // MARK: max turn duration (default unlimited)

    @Test("effectiveMaxTurnDuration is nil (unlimited) by default and for non-positive values")
    func turnDurationDefaultUnlimited() throws {
        let defaultConfig = ArcConfig()
        #expect(defaultConfig.agent.max_turn_duration == nil)
        #expect(defaultConfig.effectiveMaxTurnDuration() == nil)

        var zero = ArcConfig()
        zero.agent.max_turn_duration = 0
        #expect(zero.effectiveMaxTurnDuration() == nil)

        var negative = ArcConfig()
        negative.agent.max_turn_duration = -5
        #expect(negative.effectiveMaxTurnDuration() == nil)

        var bounded = ArcConfig()
        bounded.agent.max_turn_duration = 300
        #expect(bounded.effectiveMaxTurnDuration() == 300)
    }

    @Test("agent.max_turn_duration decodes from config JSON and ArcAgent.Configuration defaults to unlimited")
    func configDecoding() throws {
        let json = #"{"agent": {"max_turn_duration": 240}}"#.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(ArcConfig.self, from: json)
        #expect(cfg.effectiveMaxTurnDuration() == 240)

        let absent = try JSONDecoder().decode(ArcConfig.self, from: #"{}"#.data(using: .utf8)!)
        #expect(absent.effectiveMaxTurnDuration() == nil)

        // The agent default is 0 = unlimited; a positive value bounds the turn.
        let unlimited = ArcAgent.Configuration(model: "test", apiKey: "", registry: CompileTimeToolRegistry())
        #expect(unlimited.maxTurnDuration == 0)
        let bounded = ArcAgent.Configuration(model: "test", apiKey: "", registry: CompileTimeToolRegistry(), maxTurnDuration: 90)
        #expect(bounded.maxTurnDuration == 90)
    }
}
