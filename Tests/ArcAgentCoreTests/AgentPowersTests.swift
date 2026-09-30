import Foundation
import Testing
@testable import ArcAgentCore

// MARK: - Agent powers lockdown

/// All of these exercise the shared `AgentPowers` static gate, so they must
/// run serially — one test mutating the gate while another reads it would be
/// racy.
@Suite("Agent powers lockdown", .serialized)
struct AgentPowersTests {

    private nonisolated(unsafe) static var tmp: URL!

    /// Install a clean gate + temp dirs for the duration of a test.
    private func install(
        skills: AgentPowersConfig = AgentPowersConfig()
    ) async throws -> (skillsURL: URL, memoriesURL: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ap-tests-\(UUID().uuidString)")
        let skillsURL = dir.appendingPathComponent("skills")
        let memoriesURL = dir.appendingPathComponent("memories")
        try FileManager.default.createDirectory(
            at: skillsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: memoriesURL, withIntermediateDirectories: true)
        AgentPowers.configure(skills)
        AgentPowers.skillsDirectory = skillsURL
        AgentPowers.memoriesDirectory = memoriesURL
        Self.tmp = dir
        return (skillsURL, memoriesURL)
    }

    private func restore() {
        AgentPowers.configure(AgentPowersConfig())
        AgentPowers.skillsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arc/skills")
        AgentPowers.memoriesDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arc/memories")
        if let tmp = Self.tmp { try? FileManager.default.removeItem(at: tmp) }
        Self.tmp = nil
        MemoryTool.provider = nil
    }

    // MARK: skill_manage (unified arc-parity tool)

    private func fullSkill(_ name: String, desc: String, body: String) -> String {
        "---\nname: \(name)\ndescription: \(desc)\n---\n\n\(body)\n"
    }

    @Test("skill_manage create writes a SKILL.md with frontmatter")
    func createSkill() async throws {
        try await install()
        defer { restore() }
        let result = try await SkillManageTool.entry.handler([
            "action": "create", "name": "demo-skill",
            "content": fullSkill("demo-skill", desc: "A demo. Use when demoing.", body: "## Body\n\nDo the thing."),
        ])
        #expect(result.contains("Created skill 'demo-skill'"))
        let url = AgentPowers.skillsDirectory
            .appendingPathComponent("demo-skill/SKILL.md")
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.hasPrefix("---\nname: demo-skill\n"))
        #expect(content.contains("description: A demo. Use when demoing."))
        #expect(content.contains("## Body"))
    }

    @Test("skill_manage create accepts a category into frontmatter")
    func createCategory() async throws {
        try await install()
        defer { restore() }
        let result = try await SkillManageTool.entry.handler([
            "action": "create", "name": "categorised", "category": "devops",
            "content": fullSkill("categorised", desc: "d", body: "b"),
        ])
        #expect(result.contains("Created skill"))
        let url = AgentPowers.skillsDirectory.appendingPathComponent("categorised/SKILL.md")
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.contains("category: devops"))
    }

    @Test("skill_manage create refuses when the global skills lock is on")
    func createSkillGlobalLock() async throws {
        try await install(skills: AgentPowersConfig(skillsManage: false))
        defer { restore() }
        let result = try await SkillManageTool.entry.handler([
            "action": "create", "name": "demo-skill",
            "content": fullSkill("demo-skill", desc: "d", body: "c"),
        ])
        #expect(result.contains("Refused"))
        #expect(result.contains("locked"))
        #expect(!FileManager.default.fileExists(
            atPath: AgentPowers.skillsDirectory
                .appendingPathComponent("demo-skill").path))
    }

    @Test("skill_manage create refuses an existing name and points at patch/edit")
    func createExisting() async throws {
        try await install()
        defer { restore() }
        _ = try await SkillManageTool.entry.handler([
            "action": "create", "name": "demo-skill",
            "content": fullSkill("demo-skill", desc: "d", body: "c"),
        ])
        let result = try await SkillManageTool.entry.handler([
            "action": "create", "name": "demo-skill",
            "content": fullSkill("demo-skill", desc: "d2", body: "c2"),
        ])
        #expect(result.contains("already exists"))
        #expect(result.contains("patch"))
    }

    @Test("skill_manage create refuses a per-skill locked name")
    func createLockedName() async throws {
        try await install(skills: AgentPowersConfig(lockedSkills: ["demo-skill"]))
        defer { restore() }
        let result = try await SkillManageTool.entry.handler([
            "action": "create", "name": "demo-skill",
            "content": fullSkill("demo-skill", desc: "d", body: "c"),
        ])
        #expect(result.contains("Refused"))
    }

    @Test("skill_manage create validates the name and frontmatter")
    func createInvalid() async throws {
        try await install()
        defer { restore() }
        let badName = try await SkillManageTool.entry.handler([
            "action": "create", "name": "Bad Name!", "content": fullSkill("x", desc: "d", body: "c"),
        ])
        #expect(badName.contains("invalid skill name"))
        let badFront = try await SkillManageTool.entry.handler([
            "action": "create", "name": "ok-name", "content": "no frontmatter here",
        ])
        #expect(badFront.contains("frontmatter"))
        let missingDesc = try await SkillManageTool.entry.handler([
            "action": "create", "name": "ok-name-2", "content": "---\nname: ok-name-2\n---\nbody\n",
        ])
        #expect(missingDesc.contains("description"))
    }

    // MARK: skill_manage patch / edit / delete / file ops

    @Test("skill_manage patch finds and replaces text (replace_all)")
    func patchSkill() async throws {
        try await install()
        defer { restore() }
        _ = try await SkillManageTool.entry.handler([
            "action": "create", "name": "demo-skill",
            "content": fullSkill("demo-skill", desc: "d", body: "old text here"),
        ])
        let result = try await SkillManageTool.entry.handler([
            "action": "patch", "name": "demo-skill",
            "old_string": "old text", "new_string": "new text",
        ])
        #expect(result.contains("Patched skill 'demo-skill'"))
        let url = AgentPowers.skillsDirectory.appendingPathComponent("demo-skill/SKILL.md")
        let after = try String(contentsOf: url, encoding: .utf8)
        #expect(after.contains("new text here"))
        #expect(!after.contains("old text here"))

        let missing = try await SkillManageTool.entry.handler([
            "action": "patch", "name": "demo-skill",
            "old_string": "zzz", "new_string": "q",
        ])
        #expect(missing.contains("not found"))
    }

    @Test("skill_manage edit rewrites the whole SKILL.md")
    func editSkill() async throws {
        try await install()
        defer { restore() }
        _ = try await SkillManageTool.entry.handler([
            "action": "create", "name": "demo-skill",
            "content": fullSkill("demo-skill", desc: "d", body: "old body"),
        ])
        let result = try await SkillManageTool.entry.handler([
            "action": "edit", "name": "demo-skill",
            "content": fullSkill("demo-skill", desc: "new desc", body: "new body"),
        ])
        #expect(result.contains("Updated skill 'demo-skill'"))
        let url = AgentPowers.skillsDirectory.appendingPathComponent("demo-skill/SKILL.md")
        let after = try String(contentsOf: url, encoding: .utf8)
        #expect(after.contains("description: new desc"))
        #expect(after.contains("new body"))
        #expect(!after.contains("old body"))
    }

    @Test("skill_manage refuses edit/delete on locked names")
    func editLocked() async throws {
        try await install(skills: AgentPowersConfig(lockedSkills: ["demo-skill"]))
        defer { restore() }
        let result = try await SkillManageTool.entry.handler([
            "action": "edit", "name": "demo-skill",
            "content": fullSkill("demo-skill", desc: "d", body: "x"),
        ])
        #expect(result.contains("Refused"))
        let del = try await SkillManageTool.entry.handler([
            "action": "delete", "name": "demo-skill",
        ])
        #expect(del.contains("Refused"))
    }

    @Test("skill_manage reports a missing skill on edit/delete")
    func editMissing() async throws {
        try await install()
        defer { restore() }
        let result = try await SkillManageTool.entry.handler([
            "action": "edit", "name": "ghost-skill",
            "content": fullSkill("ghost-skill", desc: "d", body: "x"),
        ])
        #expect(result.contains("not found"))
        let del = try await SkillManageTool.entry.handler([
            "action": "delete", "name": "ghost-skill",
        ])
        #expect(del.contains("not found"))
    }

    @Test("skill_manage delete removes the skill and reports absorbed_into")
    func deleteSkill() async throws {
        try await install()
        defer { restore() }
        _ = try await SkillManageTool.entry.handler([
            "action": "create", "name": "doomed",
            "content": fullSkill("doomed", desc: "d", body: "c"),
        ])
        let result = try await SkillManageTool.entry.handler([
            "action": "delete", "name": "doomed", "absorbed_into": "umbrella",
        ])
        #expect(result.contains("Deleted skill 'doomed'"))
        #expect(result.contains("merged into 'umbrella'"))
        #expect(!FileManager.default.fileExists(
            atPath: AgentPowers.skillsDirectory.appendingPathComponent("doomed").path))
    }

    @Test("skill_manage write_file/remove_file stay inside the skill dir")
    func fileOps() async throws {
        try await install()
        defer { restore() }
        _ = try await SkillManageTool.entry.handler([
            "action": "create", "name": "fileskill",
            "content": fullSkill("fileskill", desc: "d", body: "c"),
        ])
        let wrote = try await SkillManageTool.entry.handler([
            "action": "write_file", "name": "fileskill",
            "file_path": "references/api.md", "file_content": "# API\n",
        ])
        #expect(wrote.contains("Wrote references/api.md"))
        let fileURL = AgentPowers.skillsDirectory
            .appendingPathComponent("fileskill/references/api.md")
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        let traversal = try await SkillManageTool.entry.handler([
            "action": "write_file", "name": "fileskill",
            "file_path": "../../escape.md", "file_content": "x",
        ])
        #expect(traversal.contains("relative path"))

        let removed = try await SkillManageTool.entry.handler([
            "action": "remove_file", "name": "fileskill", "file_path": "references/api.md",
        ])
        #expect(removed.contains("Removed references/api.md"))
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: profile_edit

    @Test("profile_edit reads and writes MEMORY.md when unlocked")
    func profileMemory() async throws {
        try await install()
        defer { restore() }
        let missing = try await ProfileEditTool.entry.handler(["file": "memory", "action": "read"])
        #expect(missing.contains("No MEMORY content yet"))
        let write = try await ProfileEditTool.entry.handler([
            "file": "memory", "action": "write", "content": "## Notes\n\nremember this"
        ])
        #expect(write.contains("Updated MEMORY"))
        let read = try await ProfileEditTool.entry.handler(["file": "memory", "action": "read"])
        #expect(read.contains("## Notes"))
        #expect(read.contains("remember this"))
    }

    @Test("profile_edit refuses locked files and global profile lock")
    func profileLocks() async throws {
        try await install(skills: AgentPowersConfig(
            profileEdit: true, lockedProfileFiles: ["memory", "agents"]))
        defer { restore() }
        let mem = try await ProfileEditTool.entry.handler([
            "file": "memory", "action": "write", "content": "x"
        ])
        #expect(mem.contains("Refused"))
        #expect(mem.contains("MEMORY is locked"))
        let agents = try await ProfileEditTool.entry.handler([
            "file": "agents", "action": "write", "content": "x"
        ])
        #expect(agents.contains("Refused"))
        // Reads are never blocked.
        let agentsRead = try await ProfileEditTool.entry.handler([
            "file": "agents", "action": "read"
        ])
        #expect(!agentsRead.contains("Refused") || agentsRead.contains("No AGENTS.md"))

        try await install(skills: AgentPowersConfig(profileEdit: false))
        let user = try await ProfileEditTool.entry.handler([
            "file": "user", "action": "write", "content": "x"
        ])
        #expect(user.contains("Refused"))
        #expect(user.contains("profile editing is locked"))
    }

    @Test("profile_edit read of AGENTS.md returns the workspace file")
    func profileAgentsRead() async throws {
        try await install()
        defer { restore() }
        let result = try await ProfileEditTool.entry.handler(["file": "agents", "action": "read"])
        // Any response (content or "No AGENTS.md") is fine; must not be a refusal.
        #expect(!result.contains("Refused"))
    }

    // MARK: memory tool gate

    @Test("memory tool refuses MEMORY writes while memory is locked")
    func memoryToolLocked() async throws {
        try await install(skills: AgentPowersConfig(
            profileEdit: true, lockedProfileFiles: ["memory"]))
        defer { restore() }
        let provider = FileMemoryProvider(directory: AgentPowers.memoriesDirectory)
        MemoryTool.provider = provider
        let result = try await MemoryTool.entry.handler([
            "action": "add", "content": "should not be stored"
        ])
        #expect(result.contains("Refused"))
        let content = try? String(contentsOf: AgentPowers.memoriesDirectory
            .appendingPathComponent("MEMORY.md"), encoding: .utf8)
        #expect(content == nil || content!.isEmpty)
    }

    // MARK: defense-in-depth path guard

    @Test("blockedWriteReason refuses locked surfaces and passes others")
    func writeGuard() async throws {
        defer { restore() }
        let (skillsURL, _) = try await install(skills: AgentPowersConfig(
            skillsManage: true, lockedSkills: ["frozen"],
            profileEdit: true, lockedProfileFiles: ["memory", "soul", "agents"]))
        _ = skillsURL
        #expect(AgentPowers.blockedWriteReason(path: "/tmp/readme.md") == nil)
        #expect(AgentPowers.blockedWriteReason(
            path: skillsURL.path + "/free-skill/SKILL.md") == nil)
        let frozen = AgentPowers.blockedWriteReason(
            path: skillsURL.path + "/frozen/refs/x.md")
        #expect(frozen?.contains("frozen") == true)
        let mem = AgentPowers.blockedWriteReason(
            path: AgentPowers.memoriesDirectory.path + "/MEMORY.md")
        #expect(mem?.contains("MEMORY") == true)
        let soul = AgentPowers.blockedWriteReason(path: "/tmp/SOUL.md")
        #expect(soul?.contains("SOUL") == true)
        let agents = AgentPowers.blockedWriteReason(path: "/tmp/proj/AGENTS.md")
        #expect(agents?.contains("Refused") == true)
    }

    @Test("write guard passes when everything is unlocked")
    func writeGuardUnlocked() async throws {
        try await install()
        defer { restore() }
        #expect(AgentPowers.blockedWriteReason(
            path: AgentPowers.skillsDirectory.path + "/anything/SKILL.md") == nil)
        #expect(AgentPowers.blockedWriteReason(
            path: AgentPowers.memoriesDirectory.path + "/MEMORY.md") == nil)
        #expect(AgentPowers.blockedWriteReason(path: "/tmp/AGENTS.md") == nil)
    }

    @Test("terminal lockdown guard blocks mutating commands, passes reads")
    func terminalGuard() async throws {
        defer { restore() }
        let (skillsURL, _) = try await install(skills: AgentPowersConfig(
            skillsManage: false, profileEdit: false))
        _ = skillsURL
        let write = TerminalTool.lockdownRefusal(
            command: "echo x > \(AgentPowers.skillsDirectory.path)/demo/SKILL.md")
        #expect(write?.contains("Refused") == true)
        let agents = TerminalTool.lockdownRefusal(command: "sed -i 's/a/b/' /tmp/AGENTS.md")
        #expect(agents?.contains("Refused") == true)
        let read = TerminalTool.lockdownRefusal(
            command: "cat \(AgentPowers.skillsDirectory.path)/demo/SKILL.md")
        #expect(read == nil)
        let normal = TerminalTool.lockdownRefusal(command: "ls -la /tmp")
        #expect(normal == nil)
    }
}
