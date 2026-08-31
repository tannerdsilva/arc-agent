import Foundation
import Testing
@testable import ArcAgentCore

// MARK: - Unit tests (always run)

@Suite("Tessera tag/sequence helpers")
struct TesseraTagTests {

    @Test("Sequence number is parsed from the d-tag tail")
    func sequenceParsing() {
        #expect(TesseraConnection.sequenceNumber(fromTagKey: "arc/s/demo/12") == 12)
        #expect(TesseraConnection.sequenceNumber(fromTagKey: "arc/m/agent/0") == 0)
        #expect(TesseraConnection.sequenceNumber(fromTagKey: "arc/meta/sess-1/300") == 300)
        #expect(TesseraConnection.sequenceNumber(fromTagKey: "arc/p/tester/7") == 7)
    }

    @Test("Non-numeric or missing tails yield nil")
    func sequenceParsingRejectsBadTails() {
        #expect(TesseraConnection.sequenceNumber(fromTagKey: "arc/s/demo/last") == nil)
        #expect(TesseraConnection.sequenceNumber(fromTagKey: "arc/s/demo/") == nil)
        #expect(TesseraConnection.sequenceNumber(fromTagKey: "arc/s/demo") == nil)
        #expect(TesseraConnection.sequenceNumber(fromTagKey: "12") == nil)
        #expect(TesseraConnection.sequenceNumber(fromTagKey: "arc/s/demo/-1") == nil)
    }

    @Test("Kind constants occupy the non-replaceable band")
    func kindConstants() {
        // All four kinds must be in 0...9,999 so the server needs no access
        // level to accept them from a registered user.
        for kind in [
            TesseraConnection.messageKind,
            TesseraConnection.memoryKind,
            TesseraConnection.metadataKind,
            TesseraConnection.profileKind,
        ] {
            #expect(kind < 10_000)
        }
    }

    @Test("TesseraConfig round-trips through Codable")
    func configCodable() throws {
        let config = TesseraConfig(
            serverIP: "127.0.0.1",
            serverPort: 51900,
            serverPublicKey: "server-pub",
            myPrivateKey: "client-priv",
            application: 1
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(TesseraConfig.self, from: data)
        #expect(decoded == config)
    }
}

// MARK: - End-to-end tests (live daemon)

/// Exercises the Tessera-backed storage against a real locally-spawned
/// Tessera server: keys generated, peer + admin registered, daemon running
/// over loopback WireGuard, then full session/memory/profile round-trips.
///
/// Opt-in via `ARC_TESSERA_E2E=1` because it needs the tessera binary
/// (default: `~/SwiftProjects/tessera/.build/debug/tessera`, override with
/// `TESSERA_BIN`) and binds a loopback UDP port. Runs serially within this
/// suite and uses a unique client identity per run.
@Suite("Tessera E2E", .serialized)
struct TesseraStorageE2ETests {

    private struct Daemon {
        let process: Process
        let databasePath: String
        let configurationPath: String
        let port: Int
        let serverPublicKey: String
        let clientPublicKey: String
        let clientPrivateKey: String

        func stop() {
            process.terminate()
            process.waitUntilExit()
            try? FileManager.default.removeItem(atPath: databasePath)
            try? FileManager.default.removeItem(atPath: configurationPath)
        }
    }

    private static func tesseraBinary() -> String? {
        let env = ProcessInfo.processInfo.environment["TESSERA_BIN"]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            env,
            "\(home)/SwiftProjects/tessera/.build/debug/tessera",
            "\(home)/SwiftProjects/tessera/.build/release/tessera",
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Runs a tessera CLI subcommand and returns its stdout.
    private static func runCommand(_ binary: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private static func parseGeneratedKeys(_ output: String) throws -> (publicKey: String, privateKey: String) {
        var pub: String?
        var priv: String?
        for line in output.split(separator: "\n") {
            let line = String(line)
            if line.hasPrefix("Public Key: ") {
                pub = String(line.dropFirst("Public Key: ".count))
            } else if line.hasPrefix("Private Key: ") {
                priv = String(line.dropFirst("Private Key: ".count))
            }
        }
        guard let pub, let priv, !pub.isEmpty, !priv.isEmpty else {
            throw TesseraStoreError.invalidKeys
        }
        return (pub, priv)
    }

    /// Spawns a fresh daemon with its own database, peer registration, and
    /// admin user, then waits for the WireGuard interface to start.
    private static func spawnDaemon(binary: String) async throws -> Daemon {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-tessera-e2e-\(UUID().uuidString)")
        // The daemon treats --database-path as a DIRECTORY and creates
        // <dir>/tessera.mdb inside it.
        let dbDir = root.appendingPathComponent("db").path
        let cfgPath = root.appendingPathComponent("cfg").path
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("db"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("cfg"),
            withIntermediateDirectories: true
        )

        let server = try parseGeneratedKeys(runCommand(binary, ["generate-keys"]))
        let client = try parseGeneratedKeys(runCommand(binary, ["generate-keys"]))

        // Register the client as a WireGuard peer and as an unbounded admin.
        _ = try runCommand(
            binary,
            ["config", "add", "--configuration-path", cfgPath, client.publicKey]
        )
        _ = try runCommand(
            binary,
            ["create-unbounded-admin", "--database-path", dbDir, client.privateKey, "arc-agent-e2e"]
        )

        // Unique port per run unless pinned via TESSERA_TEST_PORT, so parallel
        // or leaked daemons can never collide with this one.
        var port = 51900
        if let envPort = ProcessInfo.processInfo.environment["TESSERA_TEST_PORT"],
           let parsed = Int(envPort) {
            port = parsed
        } else {
            port = Int.random(in: 20_000...45_000)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "run",
            "--database-path", dbDir,
            "--configuration-path", cfgPath,
            "--sync-interval", "0",
            String(port),
            server.privateKey,
        ]
        let logURL = root.appendingPathComponent("daemon.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()

        // Wait for the WireGuard interface to be listening.
        let ready = await waitForReady(logURL: logURL, process: process)
        guard ready else {
            process.terminate()
            process.waitUntilExit()
            throw TesseraStoreError.eoseTimeout
        }

        return Daemon(
            process: process, databasePath: dbDir, configurationPath: cfgPath,
            port: port, serverPublicKey: server.publicKey,
            clientPublicKey: client.publicKey, clientPrivateKey: client.privateKey
        )
    }

    private static func waitForReady(logURL: URL, process: Process, timeout: TimeInterval = 30) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning {
                let tail = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                print("[tessera-e2e] daemon exited early; log tail: \(tail.suffix(400))")
                return false
            }
            if let content = try? String(contentsOf: logURL, encoding: .utf8),
               content.contains("WireGuard interface started") {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    @Test("Sessions and memory round-trip through a live daemon")
    func sessionAndMemoryRoundTrip() async throws {
        // Opt-in gate: the E2E suite spawns a real daemon and binds a port,
        // so it only runs with ARC_TESSERA_E2E=1.
        guard ProcessInfo.processInfo.environment["ARC_TESSERA_E2E"] == "1",
              let binary = Self.tesseraBinary() else {
            print("[tessera-e2e] skipped (env=\(ProcessInfo.processInfo.environment["ARC_TESSERA_E2E"] ?? "nil"), binary=\(Self.tesseraBinary() ?? "nil"))")
            return
        }

        let daemon = try await Self.spawnDaemon(binary: binary)
        defer { daemon.stop() }

        // Point the shared connection at the daemon.
        await TesseraConnection.shared.configure(TesseraConfig(
            serverIP: "127.0.0.1",
            serverPort: daemon.port,
            serverPublicKey: daemon.serverPublicKey,
            myPrivateKey: daemon.clientPrivateKey,
            application: 1
        ))
        defer { Task { await TesseraConnection.shared.shutdown() } }

        let sessionStore = TesseraSessionStore()
        let memoryProvider = TesseraMemoryProvider()

        // --- Memory round-trip ---
        try await memoryProvider.writeMemory("first memory line")
        try await memoryProvider.appendMemory("second memory line")
        let memory = try await memoryProvider.readMemory()
        #expect(memory == "first memory line\nsecond memory line")

        try await memoryProvider.appendUser("user profile fact")
        #expect(try await memoryProvider.readUser() == "user profile fact")

        // --- Session round-trip ---
        let session = Session(
            id: "e2e-session-1",
            createdAt: Date(),
            updatedAt: Date(),
            model: "test-model",
            provider: "test-provider",
            messages: [
                Message(role: .user, content: "Hello"),
                Message(role: .assistant, content: "Hi there"),
            ]
        )
        try await sessionStore.create(session)

        let fetched = try await sessionStore.get(id: "e2e-session-1")
        #expect(fetched != nil)
        #expect(fetched?.model == "test-model")
        #expect(fetched?.provider == "test-provider")
        #expect(fetched?.messages.count == 2)
        #expect(fetched?.messages[0].content == "Hello")
        #expect(fetched?.messages[1].content == "Hi there")

        // --- Append ---
        try await sessionStore.appendMessage(
            sessionID: "e2e-session-1",
            message: Message(role: .user, content: "Third message")
        )
        let afterAppend = try await sessionStore.get(id: "e2e-session-1")
        #expect(afterAppend?.messages.count == 3)
        #expect(afterAppend?.messages[2].content == "Third message")

        // --- List ---
        let listed = try await sessionStore.list(limit: 10)
        #expect(listed.contains { $0.id == "e2e-session-1" })

        // --- Update (meta-only change; messages preserved) ---
        let appendResult = try #require(afterAppend)
        var updated = appendResult
        updated.model = "test-model-v2"
        try await sessionStore.update(updated)
        let afterUpdate = try await sessionStore.get(id: "e2e-session-1")
        #expect(afterUpdate?.model == "test-model-v2")
        #expect(afterUpdate?.messages.count == 3)

        // --- Delete ---
        try await sessionStore.delete(id: "e2e-session-1")
        let gone = try await sessionStore.get(id: "e2e-session-1")
        #expect(gone == nil)

        // --- Persistence across reconnection ---
        // Write a session, tear the connection down, re-open, and confirm
        // the server (not just the client cache) retained the events.
        let durable = Session(
            id: "e2e-durable",
            createdAt: Date(),
            updatedAt: Date(),
            model: "m",
            provider: "p",
            messages: [Message(role: .user, content: "survives")]
        )
        try await sessionStore.create(durable)

        await TesseraConnection.shared.shutdown()
        await TesseraConnection.shared.configure(TesseraConfig(
            serverIP: "127.0.0.1",
            serverPort: daemon.port,
            serverPublicKey: daemon.serverPublicKey,
            myPrivateKey: daemon.clientPrivateKey,
            application: 1
        ))

        let reloaded = try await TesseraSessionStore().get(id: "e2e-durable")
        #expect(reloaded?.messages.first?.content == "survives")
    }
}
