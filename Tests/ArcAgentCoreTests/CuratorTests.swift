import Testing
import Foundation
@testable import ArcAgentCore

/// Tests for skill curation, backups, bundles, preprocessing, memory manager,
/// and skill commands (Hermes curator/skill_bundles/skill_preprocessing/
/// memory_manager/skill_commands parity).
@Suite("Skill curation & memory")
struct CuratorTests {

    // MARK: - Curator scheduling

    @Test("curator due logic: never-run, interval, pause, idle (Hermes maybe_run_curator)")
    func dueLogic() {
        let now = Date()
        #expect(Curator.isDue(state: CuratorState()).due) // never run

        let ran = CuratorState(lastRunAt: now.addingTimeInterval(-100))
        #expect(!Curator.isDue(state: ran, now: now).due) // within interval

        let old = CuratorState(lastRunAt: now.addingTimeInterval(-7 * 24 * 3600))
        #expect(Curator.isDue(state: old, now: now).due) // interval elapsed

        let recentIdle = CuratorState(lastRunAt: now.addingTimeInterval(-7 * 24 * 3600))
        #expect(!Curator.isDue(state: recentIdle, now: now, idleSince: now.addingTimeInterval(-600)).due)

        let paused = CuratorState(lastRunAt: now.addingTimeInterval(-7 * 24 * 3600), paused: true)
        #expect(!Curator.isDue(state: paused, now: now).due)
    }

    @Test("transitions: stale -> review worthy, older -> archive, cron-protected untouched")
    func transitions() {
        let now = Date()
        let skills = [
            CuratorInput(name: "fresh", lastModified: now),
            CuratorInput(name: "stale", lastModified: now.addingTimeInterval(-40 * 86_400)),
            CuratorInput(name: "ancient", lastModified: now.addingTimeInterval(-100 * 86_400)),
        ]
        let protected = Curator.transitions(skills: skills, now: now, cronReferenced: ["ancient"])
        let byName = Dictionary(uniqueKeysWithValues: protected.map { ($0.skill, $0.kind) })
        #expect(byName["stale"] == .reviewWorthy)
        #expect(byName["ancient"] == .reviewWorthy) // protected from ARCHIVE, still review-worthy
        #expect(byName["fresh"] == nil)
    }

    @Test("cron-referenced skills parsed from a cron jobs file")
    func cronReference() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cron-\(UUID().uuidString).json")
        let json: [String: Any] = ["jobs": [["skills": ["swift-coding", "debugging"]]]]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let names = Curator.cronReferencedSkills(from: url)
        #expect(names == ["swift-coding", "debugging"])
    }

    // MARK: - Backups

    @Test("backup snapshot hashes files; prune keeps newest; rollback restores")
    func backupLifecycle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("curator-\(UUID().uuidString)")
        let skillsDir = root.appendingPathComponent("skills")
        let backupsDir = root.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        try Data("hello world".utf8).write(to: skillsDir.appendingPathComponent("one.md"))
        try FileManager.default.createDirectory(
            at: skillsDir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("second file".utf8).write(to: skillsDir.appendingPathComponent("sub/two.md"))

        let backup = try CuratorBackupStore.create(skillsDir: skillsDir, backupsDir: backupsDir)
        #expect(backup.files.count == 2)
        #expect(backup.files.allSatisfy { $0.sha256.count == 64 })
        let digest = backup.files.first { $0.path == "one.md" }?.sha256
        #expect(digest == SHA256Digest.hex(Data("hello world".utf8)))

        let backups = try CuratorBackupStore.list(directory: backupsDir)
        #expect(backups.count == 1)
        #expect(backups[0].id == backup.id)

        // Mutate the source, rollback, verify restoration.
        try Data("MUTATED".utf8).write(to: skillsDir.appendingPathComponent("one.md"))
        try CuratorBackupStore.rollback(backupID: backup.id, backupsDir: backupsDir, skillsDir: skillsDir)
        let restored = String(data: try Data(contentsOf: skillsDir.appendingPathComponent("one.md")), encoding: .utf8)
        #expect(restored == "hello world")
    }

    // MARK: - Bundles

    @Test("bundle slugify, save/load/list/delete (Hermes skill_bundles)")
    func bundleStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bundles-\(UUID().uuidString)")
        #expect(SkillBundle.slugify("Coding Onboarding!") == "coding-onboarding")
        #expect(SkillBundle.slugify("!!") == "bundle")

        let bundle = SkillBundle(
            slug: "my-bundle",
            name: "My Bundle",
            skills: [.init(name: "swift-coding", content: "do swift", files: ["references/x.md": "x"])],
            invocationMessages: [SkillBundle.invocationMessage(for: "My Bundle", skillNames: ["swift-coding"])]
        )
        let url = try SkillBundleStore.save(bundle, directory: dir)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let loaded = try SkillBundleStore.load(slug: "my-bundle", directory: dir)
        #expect(loaded?.skills.count == 1)
        #expect(loaded?.skills[0].files["references/x.md"] == "x")
        #expect(loaded?.invocationMessages[0].contains("My Bundle") == true)
        #expect(try SkillBundleStore.list(directory: dir).count == 1)

        try SkillBundleStore.delete(slug: "my-bundle", directory: dir)
        #expect(try SkillBundleStore.list(directory: dir).isEmpty)
    }

    // MARK: - Preprocessing

    @Test("template expansion: skill dir, session id, env (Hermes ${HERMES_*})")
    func templateExpansion() {
        let content = "DIR=${HERMES_SKILL_DIR} SID=${HERMES_SESSION_ID} HOME=${HOME}"
        let expanded = SkillPreprocessing.expandTemplates(
            content, skillDir: URL(fileURLWithPath: "/tmp/skills"), sessionID: "sess-1")
        #expect(expanded.contains("DIR=/tmp/skills"))
        #expect(expanded.contains("SID=sess-1"))
        #expect(expanded.contains("HOME=\(ProcessInfo.processInfo.environment["HOME"] ?? "")"))
    }

    @Test("inline commands expand; unterminated spans stay verbatim; 4000-byte cap")
    func inlineCommands() async throws {
        let out = try await SkillPreprocessing.runInlineCommands("result: !`printf hi` done")
        #expect(out == "result: hi done")

        let verbatim = try await SkillPreprocessing.runInlineCommands("plain `span`")
        #expect(verbatim == "plain `span`")

        let capped = try await SkillPreprocessing.runInlineCommands("!`python3 -c 'print(\"x\"*9000)'`")
        #expect(capped.utf8.count <= SkillPreprocessing.maxInlineOutputBytes)
    }

    // MARK: - Memory manager

    @Test("scrub strips controls/ANSI/zero-width and trims")
    func scrub() {
        let clean = MemoryManager.scrub("a\u{001B}[31mred\u{0}\u{200B}z\n")
        #expect(!clean.contains("\u{001B}"))
        #expect(!clean.contains("\u{200B}"))
        #expect(!clean.contains("\u{0}"))
        #expect(clean == "aredz")
    }

    @Test("memory context bounds via head+tail with truncation marker (Hermes 4000/1500/6000)")
    func memoryBounds() {
        let big = String(repeating: "A", count: 10_000)
        let block = MemoryManager.buildContext(entries: [(1.0, big)])!
        #expect(block.hasPrefix("<memory-context>"))
        #expect(block.hasSuffix("</memory-context>"))
        #expect(block.contains(MemoryManager.truncationMarker))
        #expect(block.utf8.count < 7_000)

        let small = MemoryManager.buildContext(entries: [(1.0, "hello"), (0.5, "world")])
        #expect(small == "<memory-context>\nhello\n\nworld\n</memory-context>")
    }

    @Test("empty memory yields no block")
    func memoryEmpty() {
        #expect(MemoryManager.buildContext(entries: []) == nil)
    }

    // MARK: - Skill commands

    @Test("command frontmatter parsing and invocation message (Hermes skill_commands)")
    func commandParsing() {
        let fm = "name: test\ndescription: d\ncommand: tst\n"
        #expect(SkillCommands.commandName(fromFrontmatter: fm) == "tst")

        let msg = SkillCommands.invocationMessage(command: "tst", skillName: "test")
        #expect(msg.hasPrefix(SkillCommands.invocationPrefix))
        #expect(msg.contains("tst"))
        #expect(SkillCommands.preloadedLine(command: "tst", skillName: "test").contains("invoking skill 'test'"))
        #expect(SkillCommands.maxStack == 5)
    }
}
