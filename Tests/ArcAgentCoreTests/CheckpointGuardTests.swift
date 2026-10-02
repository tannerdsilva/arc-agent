import Foundation
import Testing
@testable import ArcAgentCore

// MARK: - Checkpoints & rollback (reference `tools/checkpoint_manager.py`)

/// The guard is a process singleton; serialize the suite so tests never race
/// on the shared per-turn state.
@Suite("Checkpoint guard", .serialized)
struct CheckpointGuardTests {

    /// Temporary git repo with one committed file. Callers may then create
    /// uncommitted changes to snapshot.
    private func makeRepo() async throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-cp-test-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let git = try await runGit(["init", "-q"], dir: dir)
        #expect(git.0 == 0, "git init failed: \(git.1)")
        // Identity for commits.
        _ = try await runGit(["config", "user.email", "t@test.local"], dir: dir)
        _ = try await runGit(["config", "user.name", "Test"], dir: dir)
        try Data("v1\n".utf8).write(to: URL(fileURLWithPath: dir).appendingPathComponent("file.txt"))
        _ = try await runGit(["add", "."], dir: dir)
        let commit = try await runGit(["commit", "-qm", "a"], dir: dir)
        #expect(commit.0 == 0, "commit failed: \(commit.1)")
        return dir
    }

    private func runGit(_ args: [String], dir: String) async throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func read(_ dir: String, _ file: String) -> String? {
        try? String(contentsOfFile: dir + "/" + file, encoding: .utf8)
    }

    // MARK: - Detection

    @Test("destructive command detection matches the reference set")
    func destructiveDetection() {
        let destructive = [
            "rm -rf build", "rm file.txt", "rmdir old", "mv a b", "cp a b",
            "sudo rm -rf /var/tmp/x", "sed -i s/x/y/ f.txt", "sed -i.bak s/x/y/ f",
            "git reset --hard", "git clean -fd", "git checkout .",
            "truncate -s 0 log.txt", "dd if=/dev/zero of=x bs=1", "shred file",
            "install -m 755 x y", "echo hi > out.txt", "cat a >> b",
            "FOO=1 rm -rf x",
        ]
        for command in destructive {
            #expect(CheckpointGuard.isDestructive(command), "expected destructive: \(command)")
        }
        let benign = [
            "echo hello", "ls -la", "swift build", "git status", "git log --oneline",
            "git add -A", "git commit -m x", "cat a.txt", "grep -r x .",
            "python3 script.py", "make test", "sed s/x/y/ file.txt", "# rm -rf nope",
        ]
        for command in benign {
            #expect(!CheckpointGuard.isDestructive(command), "expected benign: \(command)")
        }
    }

    @Test("scope guard rejects root and home directories")
    func scopeChecks() async throws {
        #expect(CheckpointGuard.scopeOK("/tmp/arc-cp-test"))
        #expect(!CheckpointGuard.scopeOK("/"))
        #expect(!CheckpointGuard.scopeOK(FileManager.default.homeDirectoryForCurrentUser.path))
    }

    // MARK: - Ensure semantics

    @Test("disabled guard never snapshots")
    func disabledIsNoop() async throws {
        let dir = try await makeRepo()
        // Uncommitted change exists — snapshot would be possible.
        try Data("v2\n".utf8).write(to: URL(fileURLWithPath: dir).appendingPathComponent("file.txt"))
        await CheckpointGuard.shared.setEnabled(false)
        await CheckpointGuard.shared.beginTurn()
        let cp = await CheckpointGuard.shared.ensure(directory: dir, label: "before write_file")
        #expect(cp == nil)
        await CheckpointGuard.shared.setEnabled(true)
    }

    @Test("enabled guard snapshots once per directory per turn")
    func oncePerTurn() async throws {
        let dir = try await makeRepo()
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-cp-reg-\(UUID().uuidString).json")
        CheckpointStore.setStorageURL(storeURL)
        defer { try? FileManager.default.removeItem(at: storeURL) }

        try Data("v2\n".utf8).write(to: URL(fileURLWithPath: dir).appendingPathComponent("file.txt"))

        await CheckpointGuard.shared.setEnabled(true)
        await CheckpointGuard.shared.beginTurn()

        let first = await CheckpointGuard.shared.ensure(directory: dir, label: "before write_file")
        #expect(first != nil, "expected a snapshot")
        let second = await CheckpointGuard.shared.ensure(directory: dir, label: "before patch")
        #expect(second == nil, "second snapshot in the same turn must be skipped")

        let store = try CheckpointStore()
        let list = await store.list(projectPath: dir)
        #expect(list.count == 1)

        // Next turn: a snapshot is allowed again.
        await CheckpointGuard.shared.beginTurn()
        let third = await CheckpointGuard.shared.ensure(directory: dir, label: "before patch")
        #expect(third != nil)
        // Fresh instance: the store re-reads the registry (the guard reloads
        // per ensure, and a stale instance would still show the old list).
        let fresh = try CheckpointStore()
        let list2 = await fresh.list(projectPath: dir)
        #expect(list2.count == 2, "registry has \(list2.count): \(list2.map(\.name))")
    }

    @Test("clean tree yields no checkpoint (no-change skip)")
    func noChangeSkipped() async throws {
        let dir = try await makeRepo()
        await CheckpointGuard.shared.setEnabled(true)
        await CheckpointGuard.shared.beginTurn()
        let cp = await CheckpointGuard.shared.ensure(directory: dir, label: "before write_file")
        #expect(cp == nil, "clean tree must not produce a snapshot")
    }

    @Test("rollback restores the working tree to the snapshot")
    func restoreRoundTrip() async throws {
        let dir = try await makeRepo()
        let path = URL(fileURLWithPath: dir).appendingPathComponent("file.txt")

        // Uncommitted state -> snapshot
        try Data("version-2\n".utf8).write(to: path)
        await CheckpointGuard.shared.setEnabled(true)
        await CheckpointGuard.shared.beginTurn()
        let cp = await CheckpointGuard.shared.ensure(directory: dir, label: "before patch")
        #expect(cp != nil)

        // Mutate after the snapshot
        try Data("version-3-broken\n".utf8).write(to: path)
        #expect(read(dir, "file.txt") == "version-3-broken\n")

        // Restore
        let (ok, msg) = await CheckpointMaker.restore(checkpoint: cp!, directory: dir)
        #expect(ok, "restore failed: \(msg)")
        #expect(read(dir, "file.txt") == "version-2\n")
    }

    @Test("single-file restore only affects the requested file")
    func singleFileRestore() async throws {
        let dir = try await makeRepo()
        try Data("keep\n".utf8).write(to: URL(fileURLWithPath: dir).appendingPathComponent("other.txt"))
        _ = try await runGit(["add", "."], dir: dir)
        _ = try await runGit(["commit", "-qm", "b"], dir: dir)

        let path = URL(fileURLWithPath: dir).appendingPathComponent("file.txt")
        try Data("snap\n".utf8).write(to: path)
        await CheckpointGuard.shared.setEnabled(true)
        await CheckpointGuard.shared.beginTurn()
        let cp = await CheckpointGuard.shared.ensure(directory: dir, label: "before patch")
        #expect(cp != nil)

        try Data("after\n".utf8).write(to: path)
        try Data("other-v2\n".utf8).write(to: URL(fileURLWithPath: dir).appendingPathComponent("other.txt"))

        let (ok, msg) = await CheckpointMaker.restoreFile(checkpoint: cp!, directory: dir, file: "file.txt")
        #expect(ok, "restoreFile failed: \(msg)")
        #expect(read(dir, "file.txt") == "snap\n")
        // other.txt keeps its newer content (untouched by single-file restore)
        #expect(read(dir, "other.txt") == "other-v2\n")
    }

    @Test("project root resolves to the git top level")
    func projectRoot() async throws {
        let dir = try await makeRepo()
        let sub = dir + "/sub"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        let root = await CheckpointMaker.projectRoot(for: sub)
        // Ground truth: the same git resolution (avoids /var firmlink quirks
        // where standardize/resolvingSymlinksInPath disagree with getcwd).
        let (status, gitRoot) = try await runGit(["rev-parse", "--show-toplevel"], dir: dir)
        #expect(status == 0)
        #expect(root == gitRoot.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
