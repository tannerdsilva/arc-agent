import Testing
@testable import ArcAgentCore
import Foundation

/// Deliverable mode (reference `features/deliverable-mode.md`).
@Suite("Deliverable")
struct DeliverableTests {

    @Test("extracts absolute deliverable paths and strips them")
    func extract() {
        let text = "Here is your chart at /tmp/q3-revenue.png and the report /Users/me/out.pdf"
        let (clean, paths) = DeliverableExtractor.extract(text)
        #expect(paths == ["/tmp/q3-revenue.png", "/Users/me/out.pdf"])
        #expect(!clean.contains("/tmp/q3-revenue.png"))
        #expect(clean.contains("Here is your chart at"))
    }

    @Test("ignores paths inside code fences and backticks")
    func ignoresCode() {
        let text = """
        ```bash
        cp /tmp/backup.tar.gz /tmp/other.tar.gz
        ```
        Real: /tmp/out.csv
        """
        let (clean, paths) = DeliverableExtractor.extract(text)
        #expect(paths == ["/tmp/out.csv"])
        #expect(clean.contains("backup.tar.gz"))   // fence preserved
        #expect(clean.contains("Real:"))
    }

    @Test("home-relative paths and unsupported extensions")
    func homeRelative() {
        let (_, paths) = DeliverableExtractor.extract("~/Downloads/song.mp3 and /code/main.swift")
        #expect(paths == ["~/Downloads/song.mp3"])  // .swift excluded deliberately
    }

    @Test("punctuation-adjacent paths parse; trailing dots kept out")
    func punctuation() {
        let (clean, paths) = DeliverableExtractor.extract("See /tmp/plot.png.")
        #expect(paths == ["/tmp/plot.png"])
        #expect(!clean.contains("/tmp/plot.png"))
    }
}
