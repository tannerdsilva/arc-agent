import Foundation
import Testing
import ArcAgentCore
@testable import ArcWebUI

extension ArcWebUITestRoot {
    /// The settings page speaks the domain, not the file format.
    ///
    /// Settings is where a user learns what a control means, so a copy sentence
    /// that names an internal key (`plugins.enabled`, `mcp_servers`,
    /// `~/.arc/config.json`, …) hands them a token they cannot act on: the file
    /// is an implementation detail, the setting on screen is the thing they own.
    /// Technical names stay in `///` doc comments and in code; only the literal
    /// text a user reads is policed here.
    ///
    /// A source census, because the strings are scattered across a 5,700-line
    /// view file and no rendered golden covers every branch (the empty MCP state
    /// and the populated one are different sentences). The scanner is the house
    /// Swift lexer (`SwiftSourceScanner`), so comments are not literals and a
    /// word inside `\( … )` is code, not copy.
    ///
    /// The census is deliberately narrow: it names the seven internal spellings
    /// that were measured leaking, not "every dotted word", so a legitimate
    /// literal such as `python3` or `docs/plugin-tools.md` keeps passing.
    @Suite("settings copy census", .serialized)
    struct SettingsCopyCensusTests {

        /// The internal spellings a user must never read in the settings page.
        static let internalKeys = [
            "plugins.enabled",
            "mcp_servers",
            "approvals: off",
            "guardrails.",
            "max_turns",
            "toolLoopCap",
            "~/.arc/config.json",
        ]

        /// The two files this slice owns: the settings sections and the toasts
        /// they raise.
        static let surfaces = ["Views.swift", "Actions.swift"]

        private static func source(_ name: String) throws -> String {
            try String(contentsOfFile: "Sources/ArcWebUI/\(name)", encoding: .utf8)
        }

        /// Every literal-text hit, as `file:line: token in "chunk"`.
        static func leaks(in name: String) throws -> [String] {
            let literals = SwiftSourceScanner.literals(in: try source(name), file: name)
            var found: [String] = []
            for literal in literals {
                for chunk in literal.chunks {
                    for key in internalKeys where chunk.contains(key) {
                        found.append("\(name):\(literal.line): \(key) in \"\(chunk)\"")
                    }
                }
            }
            return found
        }

        @Test("no user-facing string in the settings surfaces names an internal key")
        func settingsCopySpeaksDomain() throws {
            var leaks: [String] = []
            for surface in Self.surfaces {
                leaks += try Self.leaks(in: surface)
            }
            #expect(leaks.isEmpty, """
                user-facing settings copy names an internal configuration key:
                \(leaks.joined(separator: "\n"))
                """)
        }

        /// The census must be able to fail. A detector that quietly reads nothing
        /// reports every surface clean, which is the one failure mode a green
        /// census cannot distinguish from success.
        @Test("the census finds a key the scanner can see")
        func censusCanFail() {
            let probe = """
                // a comment naming mcp_servers is not copy
                /// a doc comment naming ~/.arc/config.json is not copy either
                let a = "the plugins.enabled allow-list"
                let b = "Written to " + path
                """
            let literals = SwiftSourceScanner.literals(in: probe, file: "probe.swift")
            let chunks = literals.flatMap(\.chunks)
            #expect(chunks.contains { $0.contains("plugins.enabled") })
            #expect(!chunks.contains { $0.contains("mcp_servers") },
                    "a comment is not a string literal")
            #expect(!chunks.contains { $0.contains("~/.arc/config.json") },
                    "a doc comment is not a string literal")
        }
    }
}
