import Foundation
import Testing

@testable import ArcWebUI
import ArcAgentCore

extension ArcWebUITestRoot {
    /// the MCP server preset contract: the form's flat text becomes a process
    /// launch spec — `command` is one argv[0], `args` are argv entries passed
    /// verbatim, `env` is a KEY=VALUE block. the matrix is pure; the filesystem
    /// seam is injected, so the "is this a path or a command line?" rule is pinned
    /// without touching disk.
    @Suite("MCP rules", .serialized)
    struct MCPRulesTests {

        private static let noFile: @Sendable (String) -> Bool = { _ in false }
        private static let anyFile: @Sendable (String) -> Bool = { _ in true }

        // MARK: name

        @Test("names are lowercase identifiers")
        func nameAccepted() throws {
            #expect(try MCPRules.normalizeName("filesystem") == "filesystem")
            #expect(try MCPRules.normalizeName("github-remote") == "github-remote")
            #expect(try MCPRules.normalizeName("  spaced  ") == "spaced")
            #expect(try MCPRules.normalizeName("s3_bucket") == "s3_bucket")
        }

        @Test("names reject the shapes that break config keys and tool arguments")
        func nameRejected() {
            #expect(throws: MCPRuleError.nameRequired) { try MCPRules.normalizeName("   ") }
            #expect(throws: MCPRuleError.nameInvalid("spaces")) { try MCPRules.normalizeName("my server") }
            #expect(throws: MCPRuleError.nameInvalid("the character 'S'")) { try MCPRules.normalizeName("Server") }
            #expect(throws: MCPRuleError.nameInvalid("the character '.'")) { try MCPRules.normalizeName("pg.tools") }
            #expect(throws: MCPRuleError.nameInvalid("it must start with a letter or digit")) {
                try MCPRules.normalizeName("-files")
            }
            #expect(throws: MCPRuleError.nameTooLong(65)) { try MCPRules.normalizeName(String(repeating: "a", count: 65)) }
        }

        // MARK: command

        @Test("a bare executable name is the normal case")
        func commandBare() throws {
            #expect(try MCPRules.normalizeCommand("arc", fileExists: Self.noFile) == "arc")
            #expect(try MCPRules.normalizeCommand("  swift  ", fileExists: Self.noFile) == "swift")
            #expect(try MCPRules.normalizeCommand("/Users/you/.build/release/MCPPack", fileExists: Self.noFile)
                == "/Users/you/.build/release/MCPPack")
        }

        @Test("a whole command line is rejected before it becomes a missing executable")
        func commandLineRejected() {
            // `arc tools mcp serve` in the Command field would be looked up as one
            // executable name and fail at launch — the single most common mistake.
            #expect(throws: MCPRuleError.commandLooksLikeCommandLine) {
                try MCPRules.normalizeCommand("arc tools mcp serve", fileExists: Self.noFile)
            }
            #expect(throws: MCPRuleError.commandRequired) {
                try MCPRules.normalizeCommand("   ", fileExists: Self.noFile)
            }
        }

        @Test("a real executable path may contain spaces")
        func commandPathWithSpaces() throws {
            // Allowed only when the path exists — otherwise it is indistinguishable
            // from a typed command line, and the strict answer is the safe one.
            let spaced = "/Applications/My App/bin/server"
            #expect(try MCPRules.normalizeCommand(spaced, fileExists: Self.anyFile) == spaced)
            #expect(throws: MCPRuleError.commandLooksLikeCommandLine) {
                try MCPRules.normalizeCommand(spaced, fileExists: Self.noFile)
            }
        }

        // MARK: args

        @Test("arguments are one per line, verbatim — no quoting, no splitting")
        func argsParsing() {
            let raw = """
            tools
            mcp

            serve
            --workspace=/Users/you/my project
            """
            #expect(MCPRules.parseArgs(raw) == [
                "tools",
                "mcp",
                "serve",
                "--workspace=/Users/you/my project",
            ])
            #expect(MCPRules.parseArgs("") == [])
            // Quotes are data, not syntax: nothing is run through a shell.
            #expect(MCPRules.parseArgs("\"--token=abc 123\"") == ["\"--token=abc 123\""])
        }

        // MARK: env

        @Test("environment lines are KEY=VALUE, empty values allowed")
        func envParsing() throws {
            let parsed = try MCPRules.parseEnv("""
            GITHUB_PERSONAL_ACCESS_TOKEN=ghp_x
            EMPTY=
            _UNDERSCORE=ok
            """)
            #expect(parsed["GITHUB_PERSONAL_ACCESS_TOKEN"] == "ghp_x")
            #expect(parsed["EMPTY"] == "")
            #expect(parsed["_UNDERSCORE"] == "ok")
            #expect(try MCPRules.parseEnv("") == [:])
        }

        @Test("environment lines reject bad keys and duplicates")
        func envRejected() {
            #expect(throws: MCPRuleError.envLineMissingEquals("NOPE")) { try MCPRules.parseEnv("NOPE") }
            #expect(throws: MCPRuleError.envKeyInvalid("1BAD")) { try MCPRules.parseEnv("1BAD=x") }
            #expect(throws: MCPRuleError.envKeyDuplicate("A")) { try MCPRules.parseEnv("A=1\nA=2") }
        }

        // MARK: plan

        @Test("a plan carries the text through to a launch config")
        func planHappyPath() throws {
            let (name, config) = try MCPRules.planEntry(
                name: "filesystem",
                command: "arc",
                argsText: "tools\nmcp\nserve",
                envText: "TOKEN=abc",
                previous: nil,
                existingNames: [])
            #expect(name == "filesystem")
            #expect(config.command == "arc")
            #expect(config.args == ["tools", "mcp", "serve"])
            #expect(config.env == ["TOKEN": "abc"])
            #expect(config.timeout == 300, "reference default")
            #expect(config.connectTimeout == 60, "reference default")
        }

        @Test("editing keeps hand-set timeouts and is not a collision with itself")
        func planPreservesTimeouts() throws {
            let previous = MCPServerConfig(command: "old", args: ["old"], timeout: 42, connectTimeout: 7)
            let (_, config) = try MCPRules.planEntry(
                name: "filesystem", command: "arc", argsText: "tools\nmcp\nserve", envText: "",
                previousName: "filesystem", previous: previous, existingNames: ["filesystem"])
            #expect(config.timeout == 42)
            #expect(config.connectTimeout == 7)
            #expect(config.command == "arc")
        }

        @Test("a rename is not a collision with the old name, but is with another server")
        func planRenameRules() throws {
            let previous = MCPServerConfig(command: "gh-mcp", args: ["serve"])
            let (name, _) = try MCPRules.planEntry(
                name: "github", command: "gh-mcp", argsText: "serve", envText: "",
                previousName: "gh", previous: previous, existingNames: ["gh", "filesystem"])
            #expect(name == "github")

            #expect(throws: MCPRuleError.nameExists("filesystem")) {
                try MCPRules.planEntry(
                    name: "filesystem", command: "gh-mcp", argsText: "", envText: "",
                    previousName: "gh", previous: previous, existingNames: ["gh", "filesystem"])
            }
        }

        @Test("a stated name collision fails loudly instead of overwriting")
        func planRejectsCollision() {
            #expect(throws: MCPRuleError.nameExists("filesystem")) {
                try MCPRules.planEntry(
                    name: "filesystem", command: "arc", argsText: "", envText: "",
                    previous: nil, existingNames: ["filesystem", "github"])
            }
        }

        /// The shape arc refuses outright, at every door the policy covers: a
        /// bare launcher, an absolute path to one, a wrapper naming one, and a
        /// path inside an installed package tree. The form must fail before the
        /// entry is written, so a saved config can never contain one.
        @Test("a package-manager launcher is refused at save time")
        func planRefusesPackageManager() {
            let cases: [(command: String, args: String)] = [
                ("npx", "-y\nsome-server"),
                ("npm", "exec\nsome-server"),
                ("/opt/homebrew/bin/pnpm", "dlx\nsome-server"),
                ("/usr/bin/env", "uvx\nsome-server"),
                ("sh", "-c\nnpx -y some-server"),
                ("node", "/usr/local/lib/node_modules/@scope/server/index.js"),
            ]
            for entry in cases {
                do {
                    _ = try MCPRules.planEntry(
                        name: "filesystem", command: entry.command, argsText: entry.args,
                        envText: "", previous: nil, existingNames: [])
                    Issue.record("'\(entry.command)' must be refused")
                } catch let error as MCPRuleError {
                    guard case .launchRefused(let reason) = error else {
                        Issue.record("wrong error for '\(entry.command)': \(error)")
                        continue
                    }
                    #expect(!reason.isEmpty)
                    #expect(reason.contains("arc"), "the refusal must name the Swift server")
                } catch {
                    Issue.record("unexpected error for '\(entry.command)': \(error)")
                }
            }
        }

        @Test("every error carries a user-facing message")
        func errorsAreDescriptive() {
            let errors: [MCPRuleError] = [
                .nameRequired, .nameTooLong(65), .nameInvalid("spaces"), .nameExists("x"),
                .commandRequired, .commandInvalid("control characters"), .commandLooksLikeCommandLine,
                .launchRefused("refused"),
                .envLineMissingEquals("NOPE"), .envKeyInvalid("1BAD"), .envKeyDuplicate("A"),
            ]
            for error in errors {
                #expect(!error.description.isEmpty)
            }
            #expect(MCPRuleError.commandLooksLikeCommandLine.description.contains("not a whole command line"))
        }
    }
}