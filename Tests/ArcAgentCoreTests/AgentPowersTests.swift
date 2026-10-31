import ArcToolKit
import Foundation
import Testing
@testable import ArcAgentCore

// MARK: - Agent powers lockdown

extension ArcCoreTestRoot {
    /// All of these exercise the shared `AgentPowers` static gate, so they must
    /// run serially — one test mutating the gate while another reads it would be
    /// racy.
    @Suite("Agent powers lockdown", .serialized)
    struct AgentPowersTests {

        private nonisolated(unsafe) static var tmp: URL!

        /// Install a clean gate + temp dirs for the duration of a test.
        @discardableResult
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
            Self.tmp = dir
            return (skillsURL, memoriesURL)
        }

        private func restore() {
            AgentPowers.configure(AgentPowersConfig())
            AgentPowers.skillsDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".arc/skills")
            if let tmp = Self.tmp { try? FileManager.default.removeItem(at: tmp) }
            Self.tmp = nil
        }

        /// The grant the installed gate hands out.
        ///
        /// The authority-bearing tools take their grant as a parameter now, so
        /// a test builds one from the gate it just installed instead of letting
        /// the tool body read the global itself.
        private func installedGrant(_ profile: String = "default") -> ToolGrant {
            AgentPowers.grant(profile: ProfileName(profile)!)
        }

        /// `profile_edit` for the gate `install()` installed, over the temp
        /// profile's documents.
        ///
        /// Built per invocation, never captured: `profileLocks` re-installs a
        /// different gate mid-test and the second call must see it. The
        /// documents root is the temp memories directory the helper created —
        /// the same place the old process-global static pointed.
        private func profileEdit(
            memories: URL,
            workspace: URL? = nil,
            profile: String = "default"
        ) -> ToolEntry {
            let grant = installedGrant(profile)
            return ProfileEditTool.entry(
                context: ToolContext(
                    profile: ProfileName(profile)!,
                    sessionID: "ap-tests",
                    workspace: (workspace ?? memories).path,
                    grant: grant
                ),
                documents: ProfileDocuments(root: memories, grant: grant),
                profiles: InMemoryProfileStore()
            )
        }

        /// `memory` for the installed gate, writing through `provider`.
        private func memoryTool(provider: any MemoryProvider, profile: String = "default") -> ToolEntry {
            MemoryTool.entry(
                context: ToolContext(
                    profile: ProfileName(profile)!,
                    sessionID: "ap-tests",
                    workspace: Self.tmp?.path ?? FileManager.default.currentDirectoryPath,
                    grant: installedGrant(profile)
                ),
                memory: provider
            )
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

        @Test("skill_manage patch reports a write it could not perform")
        func patchSkillReportsWriteFailure() async throws {
            let (skills, _) = try await install()
            defer { restore() }
            _ = try await SkillManageTool.entry.handler([
                "action": "create", "name": "demo-skill",
                "content": fullSkill("demo-skill", desc: "d", body: "old text here"),
            ])
            let dir = skills.appendingPathComponent("demo-skill")
            // a read-only directory is the exact shape of the failure the old
            // code swallowed: the atomic write cannot create its temp file, so
            // nothing reaches disk.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o555], ofItemAtPath: dir.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: dir.path)
            }
            let result = try await SkillManageTool.entry.handler([
                "action": "patch", "name": "demo-skill",
                "old_string": "old text", "new_string": "new text",
            ])
            #expect(result.hasPrefix("Error:"),
                    "a failed write must not be reported as a patch: \(result)")
            let after = try String(
                contentsOf: dir.appendingPathComponent("SKILL.md"), encoding: .utf8)
            #expect(after.contains("old text here"))
            #expect(!after.contains("new text here"))
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
            let (_, memories) = try await install()
            defer { restore() }
            let missing = try await profileEdit(memories: memories).handler(["file": "memory", "action": "read"])
            #expect(missing.contains("No MEMORY content yet"))
            let write = try await profileEdit(memories: memories).handler([
                "file": "memory", "action": "write", "content": "## Notes\n\nremember this"
            ])
            #expect(write.contains("Updated MEMORY"))
            let read = try await profileEdit(memories: memories).handler(["file": "memory", "action": "read"])
            #expect(read.contains("## Notes"))
            #expect(read.contains("remember this"))
        }

        @Test("profile_edit refuses locked files and global profile lock")
        func profileLocks() async throws {
            let (_, memories) = try await install(skills: AgentPowersConfig(
                profileEdit: true, lockedProfileFiles: ["memory", "agents"]))
            defer { restore() }
            let mem = try await profileEdit(memories: memories).handler([
                "file": "memory", "action": "write", "content": "x"
            ])
            #expect(mem.contains("Refused"))
            #expect(mem.contains("MEMORY is locked"))
            let agents = try await profileEdit(memories: memories).handler([
                "file": "agents", "action": "write", "content": "x"
            ])
            #expect(agents.contains("Refused"))
            // Reads are never blocked.
            let agentsRead = try await profileEdit(memories: memories).handler([
                "file": "agents", "action": "read"
            ])
            #expect(!agentsRead.contains("Refused") || agentsRead.contains("No AGENTS.md"))

            try await install(skills: AgentPowersConfig(profileEdit: false))
            let user = try await profileEdit(memories: memories).handler([
                "file": "user", "action": "write", "content": "x"
            ])
            #expect(user.contains("Refused"))
            #expect(user.contains("profile editing is locked"))
        }

        @Test("profile_edit read of AGENTS.md returns the workspace file")
        func profileAgentsRead() async throws {
            let (_, memories) = try await install()
            defer { restore() }
            // The workspace, not the process working directory: a fixture file
            // proves the read addresses `context.workspace`.
            let workspace = memories.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try "workspace agent notes".write(
                to: workspace.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

            let result = try await profileEdit(memories: memories, workspace: workspace)
                .handler(["file": "agents", "action": "read"])
            #expect(result.contains("workspace agent notes"))
            #expect(!result.contains("Refused"))
        }

        // MARK: memory tool gate

        @Test("memory tool refuses MEMORY writes while memory is locked")
        func memoryToolLocked() async throws {
            let (_, memories) = try await install(skills: AgentPowersConfig(
                profileEdit: true, lockedProfileFiles: ["memory"]))
            defer { restore() }
            let provider = FileMemoryProvider(directory: memories)
            let result = try await memoryTool(provider: provider).handler([
                "action": "add", "content": "should not be stored"
            ])
            #expect(result.contains("Refused"))
            let content = try? String(contentsOf: memories
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
                path: "/tmp/profiles/work/MEMORY.md")
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
                path: "/tmp/profiles/work/MEMORY.md") == nil)
            #expect(AgentPowers.blockedWriteReason(path: "/tmp/AGENTS.md") == nil)
        }

        @Test("terminal lockdown guard blocks mutating commands, passes reads")
        func terminalGuard() async throws {
            defer { restore() }
            let (skillsURL, _) = try await install(skills: AgentPowersConfig(
                skillsManage: false, profileEdit: false))
            _ = skillsURL
            let write = TerminalTool.lockdownRefusal(
                command: "echo x > \(AgentPowers.skillsDirectory.path)/demo/SKILL.md",
                grant: installedGrant())
            #expect(write?.contains("Refused") == true)
            let agents = TerminalTool.lockdownRefusal(
                command: "sed -i 's/a/b/' /tmp/AGENTS.md", grant: installedGrant())
            #expect(agents?.contains("Refused") == true)
            let read = TerminalTool.lockdownRefusal(
                command: "cat \(AgentPowers.skillsDirectory.path)/demo/SKILL.md",
                grant: installedGrant())
            #expect(read == nil)
            let normal = TerminalTool.lockdownRefusal(
                command: "ls -la /tmp", grant: installedGrant())
            #expect(normal == nil)
        }

        // MARK: ownership of the process-global gate

        /// A plainly-constructed agent (the session host's shape, and the daemon's
        /// session agents) must never reset an active lockdown. The daemon installs
        /// the gate once at boot from config.json.
        ///
        /// It lives in this serialized suite because the gate is process-global:
        /// it and the lockdown tests above mutate the same static, and when they
        /// were separate suites Swift Testing ran them in parallel with each other
        /// (serialization is within-suite) — this assert lost its window to a
        /// sibling test's `restore()` often enough to redden full suite runs.
        @Test("a default-powers agent does not clobber an active lockdown")
        func defaultAgentPreservesGate() throws {
            AgentPowers.configure(AgentPowersConfig(
                skillsManage: false,
                lockedSkills: ["secret"],
                profileEdit: false
            ))
            defer { AgentPowers.configure(AgentPowersConfig()) }

            let registry = try ArcAgentCore.testRegistry()
            _ = ArcAgent(config: ArcAgent.Configuration(
                model: "test-model",
                provider: "test",
                baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                apiKey: "",
                registry: registry,
                sessionStore: FileSessionStore(),
                memoryProvider: FileMemoryProvider(),
                skills: []
            ))

            #expect(AgentPowers.canManageSkills() == false)
            #expect(AgentPowers.skillIsLocked("secret"))
        }

        // MARK: GROUNDZERO slice 0 — pinned defects (RED)

        /// Defect: `patch` never consults the authority gate, so a locked
        /// profile document can be rewritten through it. Pinned RED; the fix
        /// lands with the grant slice.
        @Test("patch refuses a locked profile document")
        func patchRefusesLockedProfileDocument() async throws {
            let (_, memories) = try await install(skills: AgentPowersConfig(profileEdit: false))
            defer { restore() }
            let doc = memories.appendingPathComponent("MEMORY.md")
            try "alpha".write(to: doc, atomically: true, encoding: .utf8)
            let out = try await PatchTool.entry.handler([
                "path": doc.path, "old_string": "alpha", "new_string": "beta",
            ])
            #expect(out.contains("Refused:"))
        }

        /// Defect: `create_profile` applies every optional only inside its
        /// `title` branch, so model/provider/group are dropped silently when no
        /// title is given. Pinned RED; the fix lands with the roster slice.
        @Test("create_profile applies model without a title")
        func createProfileAppliesOptionsWithoutTitle() async throws {
            try await install()
            defer { restore() }
            let profilesRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("gz-profiles-\(UUID().uuidString)", isDirectory: true)
            ProfileManager.testProfilesRoot = profilesRoot.path
            defer {
                ProfileManager.testProfilesRoot = nil
                try? FileManager.default.removeItem(at: profilesRoot)
            }
            _ = try await CreateProfileTool.entry(profiles: TesseraProfileStore.shared).handler([
                "name": "gz-option", "model": "some-model",
            ])
            let profile = try await ProfileManager().get(name: "gz-option")
            #expect(profile?.model == "some-model")
        }

        /// Defect: the `memory` tool used to write through `MemoryTool.provider`
        /// while `profile_edit` read `AgentPowers.memoriesDirectory` — two
        /// addresses for one logical document. Slice 4 gives both tools one
        /// `ToolContext` and one profile directory, so the write is visible to
        /// the read. The `memory` tool has no read action (reads are prompt
        /// injection), so the assertion is made from the write side.
        @Test("memory tool and profile_edit share one document")
        func memoryToolAndProfileEditShareOneDocument() async throws {
            let (_, memories) = try await install()
            defer { restore() }
            // One profile's document root, handed to both tools.
            let provider = FileMemoryProvider(directory: memories)
            _ = try await memoryTool(provider: provider).handler([
                "target": "memory", "action": "add", "content": "ground-zero-probe",
            ])
            let read = try await profileEdit(memories: memories).handler([
                "file": "memory", "action": "read",
            ])
            #expect(read.contains("ground-zero-probe"))
        }
    }
}
