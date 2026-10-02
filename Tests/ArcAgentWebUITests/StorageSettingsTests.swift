import Foundation
import Testing

@testable import ArcWebUI
import ArcAgentCore

/// Settings → Storage: the connection model, the medium-resolution rules and
/// the tolerant settings decode for the storage keys (a hand-edited settings
/// file must never lose the connections list).
@Suite("Storage settings")
struct StorageSettingsTests {

    private static let conn = TesseraStorageConnection(
        id: "c1",
        name: "Home relay",
        serverIP: "10.0.0.1",
        serverPort: 51820,
        application: 1,
        serverPublicKey: "AAAAbbbbcccc=",
        myPrivateKey: "privateKeyAAAA"
    )

    @Test("a connection round-trips through settings")
    func connectionRoundTrips() throws {
        var settings = AppSettings()
        settings.storageConnections = [Self.conn]
        settings.activeStorage = "c1"
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(back.storageConnections == [Self.conn])
        #expect(back.activeStorage == "c1")
    }

    @Test("missing storage keys fall back to defaults (tolerant decode)")
    func missingKeysDefault() throws {
        let data = Data("{\"theme\":\"dark\"}".utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(settings.storageConnections.isEmpty)
        #expect(settings.activeStorage == "config")
    }

    @Test("resolveStorage maps the file medium")
    func resolveFile() {
        let r = resolveStorage(active: "file", connections: [Self.conn], cliTessera: nil)
        #expect(r.backend == "file")
        #expect(r.config == nil)
        #expect(r.label == "Local file storage")
    }

    @Test("resolveStorage maps config.json when the CLI tessera block exists")
    func resolveConfigPresent() {
        let t = TesseraConfig(
            serverIP: "127.0.0.1",
            serverPort: 51921,
            serverPublicKey: "AAAAbbbbcccc=",
            myPrivateKey: "privateKeyAAAA",
            application: 1
        )
        let r = resolveStorage(active: "config", connections: [], cliTessera: t)
        #expect(r.backend == "tessera")
        #expect(r.config == t)
    }

    @Test("resolveStorage falls back to file when config.json has no tessera block")
    func resolveConfigMissing() {
        let r = resolveStorage(active: "config", connections: [], cliTessera: nil)
        #expect(r.backend == "file")
        #expect(r.config == nil)
    }

    @Test("resolveStorage maps a saved connection by id")
    func resolveConnection() {
        let r = resolveStorage(active: "c1", connections: [Self.conn], cliTessera: nil)
        #expect(r.backend == "tessera")
        #expect(r.config == Self.conn.tesseraConfig)
    }

    @Test("resolveStorage treats an unknown or incomplete connection as file")
    func resolveUnknown() {
        let unknown = resolveStorage(active: "nope", connections: [Self.conn], cliTessera: nil)
        #expect(unknown.backend == "file")
        let incomplete = TesseraStorageConnection(
            id: "c2", name: "broken", serverIP: "10.0.0.1", serverPort: 51820,
            serverPublicKey: "", myPrivateKey: "")
        let r = resolveStorage(active: "c2", connections: [Self.conn, incomplete], cliTessera: nil)
        // the broken connection cannot resolve to a config, so its selection
        // degrades to file rather than producing a half-configured tunnel.
        #expect(r.backend == "file")
        #expect(incomplete.tesseraConfig == nil)
    }

    @Test("tesseraConfig validates completeness")
    func tesseraConfigValidation() {
        #expect(Self.conn.tesseraConfig != nil)
        let partial = TesseraStorageConnection(
            id: "c3", name: "partial", serverIP: "", serverPort: 0,
            serverPublicKey: "", myPrivateKey: "")
        #expect(partial.tesseraConfig == nil)
    }
}
