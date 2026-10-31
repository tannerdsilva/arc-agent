import Testing
import Foundation
import ArcAgentCore

extension ArcCoreTestRoot {

    /// One storage-medium resolver (settings backbone, slice 4).
    ///
    /// `storage.active` decides the backend every surface runs on — the daemon
    /// and the CLI used to read `tessera` *presence* while the web UI read its
    /// own `activeStorage` key, so a user who picked file storage kept getting
    /// Tessera sessions from Telegram. An absent key keeps the legacy
    /// inference, so a config written before this slice never changes medium.
    @Suite("store selection", .serialized)
    struct StoreSelectionTests {

        /// A config built from the two facts that decide the medium. `active`
        /// nil = the key is absent (the legacy-inference case).
        private func config(active: String?, tessera: Bool) throws -> ArcConfig {
            var parts: [String] = []
            if let active {
                parts.append("\"storage\": {\"active\": \"\(active)\"}")
            }
            if tessera {
                parts.append(#"""
                "tessera": {"serverIP": "10.0.0.5", "serverPort": 51921,
                            "serverPublicKey": "npub-server", "myPrivateKey": "",
                            "application": 7}
                """#)
            }
            let json = "{\(parts.joined(separator: ","))}"
            return try JSONDecoder().decode(ArcConfig.self, from: Data(json.utf8))
        }

        // MARK: - The resolver's decision table

        @Test("a tessera block with active=file stays on files")
        func policyFileWinsOverBlock() throws {
            let selection = StoreSelection.resolve(try config(active: "file", tessera: true))
            #expect(selection.backend == .file)
            #expect(selection.tessera == nil,
                    "file mode must not hand a tunnel to any consumer")
            #expect(!selection.fellBackFromPolicy, "an explicit policy is not a fallback")
        }

        @Test("a tessera block with no active key is the legacy inference")
        func legacyInferenceIsTessera() throws {
            let selection = StoreSelection.resolve(try config(active: nil, tessera: true))
            #expect(selection.backend == .tessera)
            #expect(selection.tessera?.serverIP == "10.0.0.5")
            #expect(selection.tessera?.application == 7)
        }

        @Test("active=tessera with no block falls back to files and says so")
        func policyTesseraWithoutBlockFallsBack() throws {
            let selection = StoreSelection.resolve(try config(active: "tessera", tessera: false))
            #expect(selection.backend == .file)
            #expect(selection.tessera == nil)
            #expect(selection.fellBackFromPolicy,
                    "an unhonourable policy must report the fallback it logged")
        }

        @Test("no block and no active key is files")
        func nothingConfiguredIsFile() throws {
            let selection = StoreSelection.resolve(try config(active: nil, tessera: false))
            #expect(selection.backend == .file)
            #expect(selection.tessera == nil)
            #expect(!selection.fellBackFromPolicy)
        }

        @Test("the policy spelling is case-insensitive")
        func policyIsCaseInsensitive() throws {
            #expect(StoreSelection.resolve(try config(active: "TESSERA", tessera: true)).backend == .tessera)
            #expect(StoreSelection.resolve(try config(active: " File ", tessera: true)).backend == .file)
        }

        @Test("an unknown medium falls back to files, never to a relay")
        func unknownMediumIsFile() throws {
            let selection = StoreSelection.resolve(try config(active: "s3", tessera: true))
            #expect(selection.backend == .file,
                    "an unparseable policy must not select a backend nobody described")
            #expect(selection.fellBackFromPolicy)
        }

        // MARK: - The gate: write through the store, read through the resolver

        @Test("a config written through the store resolves the medium the writer chose")
        func storeRoundTripAgrees() async throws {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-s4-resolve-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("config.json")
            try Data(#"""
            {"tessera": {"serverIP": "10.0.0.5", "serverPort": 51921,
                         "serverPublicKey": "npub-server", "myPrivateKey": "nsec-client",
                         "application": 7}}
            """#.utf8).write(to: url)

            let store = ConfigurationStore(url: url, environment: [:])

            // exactly what "Save and Connect" → StoragePolicy.write performs
            try await store.mutate { $0.storage.active = StorageMedium.file.rawValue }

            let fileSelection = StoreSelection.resolve(await store.resolved())
            #expect(fileSelection.backend == .file,
                    "the daemon's resolver must see the policy the UI wrote")

            let onDisk = try JSONDecoder().decode(ArcConfig.self, from: Data(contentsOf: url))
            #expect(onDisk.storage.active == "file")
            #expect(onDisk.tessera?.serverIP == "10.0.0.5",
                    "the tessera block stays: it is a credential, not a switch")

            try await store.mutate { $0.storage.active = StorageMedium.tessera.rawValue }
            let tesseraSelection = StoreSelection.resolve(await store.resolved())
            #expect(tesseraSelection.backend == .tessera)
            #expect(tesseraSelection.tessera?.endpointIdentity == onDisk.tessera?.endpointIdentity,
                    "the resolver reads the same endpoint the file names")
        }

        @Test("a file policy survives an environment-supplied tessera block")
        func environmentBlockCannotOverrideFilePolicy() async throws {
            // `ARC_TESSERA_*` can *create* a tessera block at resolution time.
            // Under the old inference that alone meant Tessera; the policy must
            // still win, or an operator could not force files with a relay
            // configured in the shell.
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-s4-env-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("config.json")
            try Data(#"{"storage": {"active": "file"}}"#.utf8).write(to: url)

            let store = ConfigurationStore(
                url: url,
                environment: ["ARC_TESSERA_SERVER_IP": "10.9.9.9",
                              "ARC_TESSERA_SERVER_PUBLIC_KEY": "npub-env",
                              "ARC_TESSERA_PRIVATE_KEY": "nsec-env"])
            let resolved = await store.resolved()
            #expect(resolved.tessera?.serverIP == "10.9.9.9", "the env block is resolved")

            let selection = StoreSelection.resolve(resolved)
            #expect(selection.backend == .file,
                    "storage.active wins over an environment-provided block")
        }

        @Test("the resolver is the only place a medium is decided")
        func resolverIsSingleSourced() throws {
            // source shape: the two former truths are gone from the surfaces.
            let daemon = try String(contentsOfFile: "Sources/ArcDaemon/ArcDaemon.swift", encoding: .utf8)
            #expect(daemon.contains("StoreSelection.resolve(arc)"),
                    "the daemon must resolve the medium through StoreSelection")
            #expect(!daemon.contains("WebUIStorageSelection"),
                    "the daemon must not read the web UI's settings.json for storage")

            let availability = try String(contentsOfFile: "Sources/ArcAgentCore/Storage/StoreSelection.swift",
                                          encoding: .utf8)
            #expect(availability.contains("StoreSelection.resolve(loadConfig())"),
                    "TesseraAvailability must honour the policy, not tessera-block presence")
        }
    }
}
