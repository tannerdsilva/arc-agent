import Foundation
import Testing

@testable import ArcWebUI
import ArcAgentCore

extension ArcWebUITestRoot {
    /// Settings → Storage: the connection library, its completeness rules and
    /// the tolerant settings decode for the connections list (a hand-edited
    /// settings file must never lose it).
    ///
    /// The *medium* is no longer decided here — it is `storage.active` in
    /// `config.json`, resolved by `StoreSelection` (see `StoreSelectionTests`
    /// and `StoragePolicyWriteTests`).
    @Suite("Storage settings", .serialized)
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
            let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            #expect(back.storageConnections == [Self.conn])
            // the medium is not a settings key any more: a fresh document
            // carries no selection at all.
            #expect(back.activeStorage == nil)
            #expect(back.tesseraOff == nil)
        }

        @Test("missing storage keys fall back to defaults (tolerant decode)")
        func missingKeysDefault() throws {
            let data = Data("{\"theme\":\"dark\"}".utf8)
            let settings = try JSONDecoder().decode(AppSettings.self, from: data)
            #expect(settings.storageConnections.isEmpty)
            #expect(settings.activeStorage == nil,
                    "the retired picker key defaults to absent, not to \"config\"")
            #expect(settings.tesseraOff == nil)
        }

        @Test("tesseraConfig validates completeness")
        func tesseraConfigValidation() {
            #expect(Self.conn.tesseraConfig != nil)
            let partial = TesseraStorageConnection(
                id: "c3", name: "partial", serverIP: "", serverPort: 0,
                serverPublicKey: "", myPrivateKey: "")
            #expect(partial.tesseraConfig == nil)
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

        @Test("the endpoint identity ignores the client secret")
        func endpointIdentityIgnoresSecret() {
            // config.json carries the endpoint; `.env` carries the key. The
            // picker must still recognise the connection it names.
            var stored = Self.conn.tesseraConfig!
            stored.myPrivateKey = ""
            #expect(stored.endpointIdentity == Self.conn.tesseraConfig?.endpointIdentity)
        }
    }
}
