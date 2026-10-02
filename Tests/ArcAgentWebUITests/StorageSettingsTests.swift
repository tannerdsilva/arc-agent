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

@Test("web UI storage selection loads from the settings file (tolerant)")
func storageSelectionLoadsTolerantly() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("arc-wui-sel-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }
    // full shape
    try """
    {"activeStorage": "conn-1", "storageConnections": [
      {"id": "conn-1", "name": "Relay One", "serverIP": "10.1.1.1", "serverPort": 51921,
       "application": 1, "serverPublicKey": "aaaa", "myPrivateKey": "bbbb"}
    ], "unrelated": "ignored"}
    """.data(using: .utf8)!.write(to: tmp)

    let loaded = WebUIStorageSelection.load(from: tmp)
    #expect(loaded != nil)
    #expect(loaded?.activeStorage == "conn-1")
    #expect(loaded?.connections.count == 1)
    #expect(loaded?.connections.first?.name == "Relay One")
    #expect(loaded?.connections.first?.tesseraConfig != nil)
}

@Test("missing keys fall back to the CLI defaults")
func storageSelectionMissingKeysFallsBack() {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("arc-wui-sel2-\(UUID().uuidString).json")
    try? """
    {"theme": "dark"}
    """.data(using: .utf8)!.write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }
    #expect(WebUIStorageSelection.load(from: tmp) == nil)
}
}

@Test("legacy clientPrivateKey is tolerated on decode and re-encoded as myPrivateKey")
func legacyKeyDecode() throws {
    let json = """
    {"id":"AB12","name":"RPI","serverIP":"10.0.0.1","serverPort":51921,"application":1,
     "serverPublicKey":"pub","clientPrivateKey":"the-real-client-key"}
    """.data(using: .utf8)!
    let conn = try JSONDecoder().decode(TesseraStorageConnection.self, from: json)
    #expect(conn.myPrivateKey == "the-real-client-key")
    #expect(conn.isComplete)

    let out = try JSONEncoder().encode(conn)
    let obj = try JSONSerialization.jsonObject(with: out) as! [String: Any]
    #expect(obj["myPrivateKey"] as? String == "the-real-client-key")
    #expect(obj["clientPrivateKey"] == nil)
}

@Test("completenessNote names what is missing")
func completenessNotes() {
    var conn = TesseraStorageConnection(name: "X", serverIP: "", serverPort: 51921, application: 1, serverPublicKey: "p", myPrivateKey: "k")
    #expect(conn.completenessNote?.contains("server IP") == true)
    conn = TesseraStorageConnection(name: "X", serverIP: "1.2.3.4", serverPort: 51921, application: 1, serverPublicKey: "p", myPrivateKey: "")
    #expect(conn.completenessNote?.contains("client private key") == true)
    conn = TesseraStorageConnection(name: "X", serverIP: "1.2.3.4", serverPort: 51921, application: 1, serverPublicKey: "p", myPrivateKey: "k")
    #expect(conn.completenessNote == nil)
}
