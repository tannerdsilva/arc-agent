import Foundation
import Testing
import ArcAgentCore
@testable import arc_agent_webui

/// Serializes suites that install the shared `AppState.settingsURLOverride`
/// test seam (Settings-persistence tests). Swift Testing parallelizes across
/// suites even when each is `.serialized`, so the static profile override must
/// be guarded by one lock shared by every suite that touches it.
///
/// Note: an actor alone is NOT sufficient — awaiting `op()` inside the actor
/// method yields the actor at suspension points, letting another suite's `run`
/// enter with a different override installed. Tasks are chained instead: each
/// `run` waits for the previous op to fully complete before starting its own.
actor WebUITestSeamLock {
    static let shared = WebUITestSeamLock()
    private var chain: Task<Void, Never>?

    func run<T: Sendable>(_ op: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = chain
        let current: Task<T, Error> = Task { @MainActor in
            await previous?.value
            return try await op()
        }
        chain = Task { _ = try? await current.value }
        return try await current.value
    }
}

/// Unit coverage for the Settings → Storage medium picker:
/// connection profiles, resolution rules, and the "Save and Connect" flow.
/// DOM-level behavior is covered by the live E2E pass.
@Suite("Storage medium picker")
struct StorageConnectionTests {

    private func sampleConn(_ id: String = "c1") -> TesseraStorageConnection {
        TesseraStorageConnection(
            id: id,
            name: "Home relay",
            serverIP: "10.0.0.1",
            serverPort: 51820,
            application: 7,
            serverPublicKey: "BASE64PUBKEY",
            myPrivateKey: "BASE64PRIVKEY"
        )
    }

    @Test("file medium always resolves to file storage")
    func fileResolves() {
        let r = resolveStorage(active: "file", connections: [sampleConn()], cliTessera: nil)
        #expect(r.backend == "file")
        #expect(r.config == nil)
    }

    @Test("config medium uses the CLI tessera block when present")
    func configResolves() {
        let cli = TesseraConfig(serverIP: "10.9.9.9", serverPort: 1234, serverPublicKey: "P", myPrivateKey: "K")
        let r = resolveStorage(active: "config", connections: [sampleConn()], cliTessera: cli)
        #expect(r.backend == "tessera")
        #expect(r.config == cli)
        #expect(r.label.contains("10.9.9.9"))
    }

    @Test("config medium falls back to file when the CLI block is missing")
    func configFallback() {
        let r = resolveStorage(active: "config", connections: [sampleConn()], cliTessera: nil)
        #expect(r.backend == "file")
        #expect(r.config == nil)
    }

    @Test("a connection id resolves to that connection's config")
    func connectionResolves() {
        let conn = sampleConn("relay-a")
        let r = resolveStorage(active: "relay-a", connections: [conn], cliTessera: nil)
        #expect(r.backend == "tessera")
        #expect(r.config == conn.tesseraConfig)
    }

    @Test("an unknown or empty connection id falls back to file, never crashes")
    func unknownFallsBack() {
        let r1 = resolveStorage(active: "ghost", connections: [sampleConn()], cliTessera: nil)
        #expect(r1.backend == "file")
        let r2 = resolveStorage(active: "ghost", connections: [sampleConn()], cliTessera: TesseraConfig(serverIP: "x", serverPort: 1, serverPublicKey: "p", myPrivateKey: "k"))
        // Unknown id must NOT silently use the CLI config — file is the safe label.
        #expect(r2.backend == "file")
    }

    @Test("a connection missing required fields yields no config")
    func incompleteConnectionIsRejected() {
        let bad = TesseraStorageConnection(
            id: "bad", name: "Broken",
            serverIP: "", serverPort: 0,
            serverPublicKey: "", myPrivateKey: ""
        )
        #expect(bad.tesseraConfig == nil)
        let r = resolveStorage(active: "bad", connections: [bad], cliTessera: nil)
        #expect(r.backend == "file")
    }

    @Test("old settings files decode with tolerant defaults (no wipe)")
    func legacySettingsDecode() throws {
        let json = """
        {"theme":"dark","tesseraOff":true}
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(settings.storageConnections.isEmpty)
        // A legacy tessera-off file must still resolve to file on first load.
        #expect(settings.activeStorage == "file")
        #expect(settings.tesseraOff == true)
    }

    @Test("new settings round-trip connections and active medium")
    func settingsRoundTrip() throws {
        var mut = AppSettings()
        mut.storageConnections = [sampleConn("r1"), sampleConn("r2")]
        mut.activeStorage = "r2"
        let data = try JSONEncoder().encode(mut)
        let read = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(read.storageConnections.count == 2)
        #expect(read.activeStorage == "r2")
        #expect(read.storageConnections[1].name == sampleConn().name)
    }
}

/// "Save and Connect" behavior — the staged pick persists only on connect, and
/// an explicit connect clears both the legacy toggle and the transient
/// boot-time fallback flag (parity with setTesseraOff).
@MainActor
@Suite("Save and Connect", .serialized)
struct StorageConnectTests {

    private func withTempSettings<T: Sendable>(_ body: @escaping @MainActor () async throws -> T) async throws -> T {
        try await WebUITestSeamLock.shared.run {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-webui-storage-test-\(UUID().uuidString).json")
            AppState.settingsURLOverride = url
            defer {
                AppState.settingsURLOverride = nil
                try? FileManager.default.removeItem(at: url)
            }
            return try await body()
        }
    }

    @Test("staging does not persist; connect persists and clears transient flags")
    func connectPersistsAndClears() async throws {
        try await withTempSettings {
            let seamPath = AppState.settingsURLOverride!.path
            let resolved = AppState.settingsURL.path
            #expect(resolved == seamPath, "settingsURL resolved to \(resolved), seam \(seamPath)")
            let app = try AppState()
            await app.forceTesseraOff()
            await app.setTesseraOff(true)

            // Staging alone must not touch the disk.
            await app.setStagedStorage("file")
            let reloadedWhileStaged = AppState.loadSettings()
            let diskWhileStaged = (try? String(contentsOf: AppState.settingsURLOverride!, encoding: .utf8)) ?? "<no file>"
            #expect(reloadedWhileStaged.activeStorage == "config", "default, unchanged; on-disk: \(diskWhileStaged)")
            let staged = await app.stagedStorage
            #expect(staged == "file")

            let ok = await app.connectStagedStorage()
            let active = await app.settings.activeStorage
            let tessOff = await app.settings.tesseraOff
            let runtimeOff = await app.runtimeTesseraOff
            #expect(ok)
            #expect(active == "file")
            #expect(tessOff == false)
            #expect(runtimeOff == false)

            let reloaded = AppState.loadSettings()
            let disk = (try? String(contentsOf: AppState.settingsURLOverride!, encoding: .utf8)) ?? "<no file>"
            #expect(reloaded.activeStorage == "file", "on-disk: \(disk)")
        }
    }

    @Test("connect with no staged pick is a no-op")
    func connectNoopWithoutStaged() async throws {
        try await withTempSettings {
            let app = try AppState()
            let ok = await app.connectStagedStorage()
            let active = await app.settings.activeStorage
            #expect(!ok)
            #expect(active == "config")
        }
    }

    @Test("connecting to an incomplete connection is refused")
    func connectRefusesIncomplete() async throws {
        try await withTempSettings {
            let app = try AppState()
            // Saving requires a name/IP/port, but empty keys still leave the
            // connection unconnectable (tesseraConfig == nil).
            let saved = await app.saveStorageConnection(
                id: "bad", name: "Broken", serverIP: "10.0.0.1", serverPort: 51820,
                application: 1, serverPublicKey: "", myPrivateKey: "")
            #expect(saved)
            let first = await app.settings.storageConnections.first
            #expect(first?.id == "bad")
            await app.setStagedStorage("bad")
            let ok = await app.connectStagedStorage()
            let active = await app.settings.activeStorage
            #expect(!ok)
            #expect(active == "config")
        }
    }

    @Test("save + edit + remove lifecycle keeps the connections list consistent")
    func saveAndRemove() async throws {
        try await withTempSettings {
            let app = try AppState()
            let saved = await app.saveStorageConnection(
                id: nil, name: "Home relay", serverIP: "10.0.0.1", serverPort: 51820,
                application: 1, serverPublicKey: "P", myPrivateKey: "K")
            #expect(saved)
            let conns = await app.settings.storageConnections
            #expect(conns.count == 1)
            let id = conns[0].id

            // Update the same connection via its id (edit path).
            let updated = await app.saveStorageConnection(
                id: id, name: "Home relay 2", serverIP: "10.0.0.2", serverPort: 51821,
                application: 2, serverPublicKey: "P2", myPrivateKey: "K2")
            #expect(updated)
            let afterEdit = await app.settings.storageConnections
            #expect(afterEdit.count == 1)
            #expect(afterEdit.first?.name == "Home relay 2")

            await app.removeStorageConnection(id: id)
            let afterRemove = await app.settings.storageConnections
            #expect(afterRemove.isEmpty)
        }
    }
}
