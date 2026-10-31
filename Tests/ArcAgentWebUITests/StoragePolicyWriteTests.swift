import Testing
import Foundation
import ArcAgentCore
@testable import ArcWebUI

extension ArcWebUITestRoot {

    /// The policy write behind "Save and Connect" (settings backbone, slice 4).
    ///
    /// The handler used to set `settings.activeStorage` and rebuild its own
    /// runtime, so the picker never reached the daemon. `StoragePolicy.write`
    /// is the extracted, network-free half: one `ConfigurationStore.mutate`
    /// carries `storage.active` and — for a saved connection — the `tessera`
    /// block it points at, with `saveConfig` splitting the private key into
    /// `.env`.
    @Suite("storage policy write", .serialized)
    struct StoragePolicyWriteTests {

        private static let connection = TesseraStorageConnection(
            id: "conn-1",
            name: "Home node",
            serverIP: "10.0.0.5",
            serverPort: 51921,
            application: 7,
            serverPublicKey: "npub-server",
            myPrivateKey: "nsec-client-secret"
        )

        /// A scratch `config.json` holding exactly `json`.
        private func scratch(_ json: String) throws -> (url: URL, store: ConfigurationStore) {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-s4-policy-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("config.json")
            try Data(json.utf8).write(to: url)
            return (url, ConfigurationStore(url: url, environment: [:]))
        }

        private func text(_ url: URL) throws -> String {
            try String(contentsOf: url, encoding: .utf8)
        }

        @Test("a saved connection becomes config.tessera + storage.active in one write")
        func connectionBecomesPolicy() async throws {
            let (url, store) = try scratch(#"{"storage": {"active": "file"}, "model": {"defaultModel": "m"}}"#)

            let snapshot = try await StoragePolicy.write(
                medium: Self.connection.id,
                connections: [Self.connection],
                to: store
            )

            // the policy the daemon resolves
            #expect(snapshot.declared.storage.active == StorageMedium.tessera.rawValue)
            #expect(StoreSelection.resolve(snapshot.declared).backend == .tessera)
            #expect(StoreSelection.resolve(await store.resolved()).backend == .tessera)

            // the credential reached the file, minus its secret
            let config = try JSONDecoder().decode(ArcConfig.self, from: Data(contentsOf: url))
            #expect(config.tessera?.serverIP == "10.0.0.5")
            #expect(config.tessera?.serverPort == 51921)
            #expect(config.tessera?.serverPublicKey == "npub-server")
            #expect(config.tessera?.application == 7)
            #expect(config.tessera?.myPrivateKey == "",
                    "the client private key never goes into config.json")
            #expect(!(try text(url)).contains("nsec-client-secret"),
                    "no secret may appear in the config document")

            // …and it is in .env, where `saveConfig` puts it
            let dotenv = try text(url.deletingLastPathComponent().appendingPathComponent(".env"))
            #expect(dotenv.contains("ARC_TESSERA_PRIVATE_KEY=nsec-client-secret"),
                    "the key moved to .env rather than being dropped")
            #expect((await store.resolved()).tessera?.myPrivateKey == "nsec-client-secret",
                    "resolution reads the key back from .env")

            // ONE write: `.bak` is the generation before it, so an
            // intermediate write would have left the new policy (or the
            // tunnel) in the backup.
            let backup = try JSONDecoder().decode(
                ArcConfig.self,
                from: Data(contentsOf: url.appendingPathExtension("bak")))
            #expect(backup.storage.active == "file",
                    "the backup predates the policy change")
            #expect(backup.tessera == nil,
                    "the tunnel and the policy landed in the same write")
        }

        @Test("choosing files keeps the tessera block as a credential")
        func fileKeepsTheBlock() async throws {
            let (url, store) = try scratch(#"""
            {"tessera": {"serverIP": "10.0.0.5", "serverPort": 51921,
                         "serverPublicKey": "npub-server", "myPrivateKey": "nsec-client-secret",
                         "application": 7}}
            """#)

            try await StoragePolicy.write(medium: StorageMedium.file.rawValue,
                                          connections: [], to: store)

            let config = try JSONDecoder().decode(ArcConfig.self, from: Data(contentsOf: url))
            #expect(config.storage.active == StorageMedium.file.rawValue)
            #expect(config.tessera?.serverIP == "10.0.0.5",
                    "switching to files must not throw the credential away")
            #expect(StoreSelection.resolve(await store.resolved()).backend == .file)
        }

        @Test("the default medium selects the block already in config.json")
        func configMediumSelectsTheBlock() async throws {
            let (_, store) = try scratch(#"""
            {"tessera": {"serverIP": "10.0.0.5", "serverPort": 51921,
                         "serverPublicKey": "npub-server", "myPrivateKey": "",
                         "application": 7}}
            """#)

            try await StoragePolicy.write(medium: "config", connections: [], to: store)

            #expect(await store.declared().storage.active == StorageMedium.tessera.rawValue)
            #expect(StoreSelection.resolve(await store.resolved()).backend == .tessera)
        }

        @Test("a pick that cannot be expressed writes nothing")
        func failedWritesLeaveTheFileAlone() async throws {
            let (url, store) = try scratch(#"{"storage": {"active": "file"}}"#)
            let before = try text(url)

            await #expect(throws: StoragePolicy.Failure.noTesseraBlock) {
                try await StoragePolicy.write(medium: "config", connections: [], to: store)
            }

            let incomplete = TesseraStorageConnection(
                id: "conn-2", name: "Broken", serverIP: "10.0.0.5",
                serverPort: 51921, serverPublicKey: "", myPrivateKey: "")
            await #expect(throws: StoragePolicy.Failure.incompleteConnection) {
                try await StoragePolicy.write(medium: incomplete.id,
                                              connections: [incomplete], to: store)
            }

            #expect(try text(url) == before, "a refused pick must leave the bytes untouched")
            #expect(await store.declared().storage.active == "file")
            #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path),
                    "no write means no backup")
        }

        @Test("the written policy and the picker agree on the medium")
        func writtenPolicyMatchesThePicker() async throws {
            let (_, store) = try scratch("{}")
            try await StoragePolicy.write(medium: Self.connection.id,
                                          connections: [Self.connection], to: store)

            let selection = StoreSelection.resolve(await store.resolved())
            #expect(storageMediumID(for: selection, connections: [Self.connection]) == Self.connection.id,
                    "the picker row that names the resolved endpoint must read as active")
        }
    }
}
