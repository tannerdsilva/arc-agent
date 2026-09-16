import Foundation
import Testing
@testable import ArcAgentCore

@Suite("SkillCommands (Hernes slash parity)")
struct SkillCommandsTests {

    // MARK: Fixtures

    func makeSkillDir() -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("arc-skillcmd-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let alpha = root.appendingPathComponent("alpha-helper")
        let beta = root.appendingPathComponent("beta-helper")
        let reserved = root.appendingPathComponent("help")
        try? FileManager.default.createDirectory(at: alpha.appendingPathComponent("references"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: reserved, withIntermediateDirectories: true)

        let alphaMd = """
        ---
        name: alpha-helper
        description: Does A.
        category: testing
        ---

        # Alpha Steps
        1. Do the alpha thing.
        """
        try? alphaMd.write(to: alpha.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try? "# Alpha reference\n".write(
            to: alpha.appendingPathComponent("references/ref.md"), atomically: true, encoding: .utf8)

        let betaMd = """
        ---
        name: beta_helper
        description: Does B.
        ---

        # Beta Steps
        - Do the beta thing.
        """
        try? betaMd.write(to: beta.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let helpMd = """
        ---
        name: help
        description: Collides with builtin.
        ---

        # Reserved
        """
        try? helpMd.write(to: reserved.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return root
    }

    // MARK: Slugs + registry

    @Test("sanitizeSlug normalizes to hyphen slugs")
    func slugNormalization() {
        #expect(SkillCommands.sanitizeSlug("My_Skill +v2") == "my-skill-v2")
        #expect(SkillCommands.sanitizeSlug("git__helper") == "git-helper")
        #expect(SkillCommands.sanitizeSlug("plain") == "plain")
        #expect(SkillCommands.sanitizeSlug("-leading-") == "leading")
    }

    @Test("registry maps /slug keys and skips reserved collisions")
    func registry() throws {
        let dir = makeSkillDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cmds = SkillCommands.getSkillCommands(directory: dir)
        #expect(cmds["/alpha-helper"] != nil)
        #expect(cmds["/beta-helper"] != nil)
        // A skill named after a builtin command is not auto-registered.
        #expect(cmds["/help"] == nil)
        #expect(cmds["/alpha-helper"]?.name == "alpha-helper")
        #expect(cmds["/alpha-helper"]?.description == "Does A.")
    }

    // MARK: Resolution

    @Test("resolve treats underscores and hyphens interchangeably")
    func resolution() throws {
        let dir = makeSkillDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(SkillCommands.resolveSkillCommandKey("alpha-helper", directory: dir) == "/alpha-helper")
        #expect(SkillCommands.resolveSkillCommandKey("beta_helper", directory: dir) == "/beta-helper")
        #expect(SkillCommands.resolveSkillCommandKey("nope", directory: dir) == nil)
    }

    // MARK: Single invocation

    @Test("single invocation embeds activation note, content, dir, files, instruction")
    func singleInvocation() throws {
        let dir = makeSkillDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let msg = SkillCommands.buildSkillInvocationMessage("/alpha-helper", userInstruction: "clean up", directory: dir)
        let text = try #require(msg)
        #expect(text.contains("IMPORTANT: The user has invoked the \"alpha-helper\""))
        #expect(text.contains("The full skill content is loaded below."))
        #expect(text.contains("# Alpha Steps"))
        // Derive the expected directory from the registry (the API may
        // canonicalize the temp path, e.g. /var -> /private/var).
        let expectedDir = SkillCommands.getSkillCommands(directory: dir)["/alpha-helper"]?.skillDir.path ?? ""
        #expect(text.contains("[Skill directory: \(expectedDir)]"))
        #expect(text.contains("[This skill has supporting files:]"))
        #expect(text.contains("references/ref.md"))
        #expect(text.contains("The user has provided the following instruction alongside the skill invocation: clean up"))
    }

    @Test("unknown single invocation yields nil")
    func unknownSingle() throws {
        let dir = makeSkillDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(SkillCommands.buildSkillInvocationMessage("/nope", directory: dir) == nil)
    }

    // MARK: Stacked invocations

    @Test("expandSlashCommand expands single and stacked skill calls")
    func expand() throws {
        let dir = makeSkillDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let single = SkillCommands.expandSlashCommand("/alpha-helper clean up", directory: dir)
        #expect(single?.contains("clean up") == true)

        let stacked = SkillCommands.expandSlashCommand("/alpha-helper /beta_helper build it", directory: dir)
        let text = try #require(stacked)
        #expect(text.contains("stacked skill bundle"))
        #expect(text.contains("alpha-helper"))
        #expect(text.contains("beta_helper"))
        #expect(text.contains("User instruction: build it"))

        #expect(SkillCommands.expandSlashCommand("plain text", directory: dir) == nil)
        #expect(SkillCommands.expandSlashCommand("/unknown thing", directory: dir) == nil)
    }

    @Test("unresolvable leading token stays in the instruction (single invocation)")
    func stackedWithUnknownTokenStaysSingle() throws {
        let dir = makeSkillDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let msg = SkillCommands.expandSlashCommand("/alpha-helper /missing run", directory: dir)
        let text = try #require(msg)
        // Hermes parity: split_stacked_skill_commands only consumes KNOWN
        // skill tokens; the unknown token falls through to the instruction.
        #expect(!text.contains("stacked skill bundle"))
        #expect(text.contains("The user has provided the following instruction alongside the skill invocation: /missing run"))
    }

    @Test("splitStacked caps at maxStackedSkills")
    func stackedCap() throws {
        let dir = makeSkillDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Create enough skill dirs to overflow the stack cap.
        for i in 0..<7 {
            let d = dir.appendingPathComponent("skill-\(i)")
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            let md = "---\nname: skill-\(i)\ndescription: S\(i).\n---\n\n# S\(i)\n"
            try? md.write(to: d.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        let rest = "/skill-1 /skill-2 /skill-3 /skill-4 /skill-5 /skill-6 the end"
        let (keys, instruction) = SkillCommands.splitStackedSkillCommands(rest, directory: dir)
        #expect(keys.count == SkillCommands.maxStackedSkills - 1)
        #expect(instruction == "/skill-5 /skill-6 the end")
    }
}
