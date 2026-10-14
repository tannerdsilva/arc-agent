import Foundation
import Testing

@testable import ArcWebUI
import ArcAgentCore

/// the MCP server preset contract: the form's flat text becomes a process
/// launch spec — `command` is one argv[0], `args` are argv entries passed
/// verbatim, `env` is a KEY=VALUE block. the matrix is pure; the filesystem
/// seam is injected, so the "is this a path or a command line?" rule is pinned
/// without touching disk.
@Suite("MCP rules")
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
        #expect(try MCPRules.normalizeCommand("npx", fileExists: Self.noFile) == "npx")
        #expect(try MCPRules.normalizeCommand("  python3  ", fileExists: Self.noFile) == "python3")
        #expect(try MCPRules.normalizeCommand("/usr/local/bin/uv", fileExists: Self.noFile) == "/usr/local/bin/uv")
    }

    @Test("a whole command line is rejected before it becomes a missing executable")
    func commandLineRejected() {
        // `npx -y server` in the Command field would be looked up as one
        // executable name and fail at launch — the single most common mistake.
        #expect(throws: MCPRuleError.commandLooksLikeCommandLine) {
            try MCPRules.normalizeCommand("npx -y @modelcontextprotocol/server-filesystem", fileExists: Self.noFile)
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
        -y

        @modelcontextprotocol/server-filesystem
        /Users/you/my project
        """
        #expect(MCPRules.parseArgs(raw) == [
            "-y",
            "@modelcontextprotocol/server-filesystem",
            "/Users/you/my project",
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
            command: "npx",
            argsText: "-y\n@modelcontextprotocol/server-filesystem\n/tmp",
            envText: "TOKEN=abc",
            previous: nil,
            existingNames: [])
        #expect(name == "filesystem")
        #expect(config.command == "npx")
        #expect(config.args == ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"])
        #expect(config.env == ["TOKEN": "abc"])
        #expect(config.timeout == 300, "reference default")
        #expect(config.connectTimeout == 60, "reference default")
    }

    @Test("editing keeps hand-set timeouts and is not a collision with itself")
    func planPreservesTimeouts() throws {
        let previous = MCPServerConfig(command: "old", args: ["old"], timeout: 42, connectTimeout: 7)
        let (_, config) = try MCPRules.planEntry(
            name: "filesystem", command: "npx", argsText: "-y\nsrv", envText: "",
            previousName: "filesystem", previous: previous, existingNames: ["filesystem"])
        #expect(config.timeout == 42)
        #expect(config.connectTimeout == 7)
        #expect(config.command == "npx")
    }

    @Test("a rename is not a collision with the old name, but is with another server")
    func planRenameRules() throws {
        let previous = MCPServerConfig(command: "npx", args: ["-y", "srv"])
        let (name, _) = try MCPRules.planEntry(
            name: "github", command: "npx", argsText: "-y\ngit", envText: "",
            previousName: "gh", previous: previous, existingNames: ["gh", "filesystem"])
        #expect(name == "github")

        #expect(throws: MCPRuleError.nameExists("filesystem")) {
            try MCPRules.planEntry(
                name: "filesystem", command: "npx", argsText: "", envText: "",
                previousName: "gh", previous: previous, existingNames: ["gh", "filesystem"])
        }
    }

    @Test("a stated name collision fails loudly instead of overwriting")
    func planRejectsCollision() {
        #expect(throws: MCPRuleError.nameExists("filesystem")) {
            try MCPRules.planEntry(
                name: "filesystem", command: "npx", argsText: "", envText: "",
                previous: nil, existingNames: ["filesystem", "github"])
        }
    }

    @Test("every error carries a user-facing message")
    func errorsAreDescriptive() {
        let errors: [MCPRuleError] = [
            .nameRequired, .nameTooLong(65), .nameInvalid("spaces"), .nameExists("x"),
            .commandRequired, .commandInvalid("control characters"), .commandLooksLikeCommandLine,
            .envLineMissingEquals("NOPE"), .envKeyInvalid("1BAD"), .envKeyDuplicate("A"),
        ]
        for error in errors {
            #expect(!error.description.isEmpty)
        }
        #expect(MCPRuleError.commandLooksLikeCommandLine.description.contains("not a whole command line"))
    }
}