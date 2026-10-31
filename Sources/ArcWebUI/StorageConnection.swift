import Foundation
import ArcAgentCore

/// A configured Tessera storage connection the user can switch to from
/// Settings → Storage. Persisted in `~/.arc-agent-webui/settings.json`
/// (`storageConnections`), independent of the CLI's `tessera` block in
/// `~/.arc/config.json` (which remains selectable as the "Default (config.json)"
/// medium).
public struct TesseraStorageConnection: Codable, Equatable, Identifiable, Sendable {
    enum CodingKeys: String, CodingKey {
        case id, name, serverIP, serverPort, application, serverPublicKey
        case myPrivateKey
        /// Legacy pre-merge settings wrote the key under this name; tolerate
        /// both keys on decode (encode always uses `myPrivateKey`).
        case legacyClientPrivateKey = "clientPrivateKey"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        serverIP = try c.decodeIfPresent(String.self, forKey: .serverIP) ?? ""
        serverPort = try c.decodeIfPresent(Int.self, forKey: .serverPort) ?? 51921
        application = try c.decodeIfPresent(UInt16.self, forKey: .application) ?? 1
        serverPublicKey = try c.decodeIfPresent(String.self, forKey: .serverPublicKey) ?? ""
        myPrivateKey = try c.decodeIfPresent(String.self, forKey: .legacyClientPrivateKey)
            ?? c.decodeIfPresent(String.self, forKey: .myPrivateKey)
            ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(serverIP, forKey: .serverIP)
        try c.encode(serverPort, forKey: .serverPort)
        try c.encode(application, forKey: .application)
        try c.encode(serverPublicKey, forKey: .serverPublicKey)
        try c.encode(myPrivateKey, forKey: .myPrivateKey)
    }
    public var id: String
    public var name: String
    public var serverIP: String
    public var serverPort: Int
    public var application: UInt16
    public var serverPublicKey: String
    public var myPrivateKey: String

    public init(
        id: String = UUID().uuidString,
        name: String,
        serverIP: String,
        serverPort: Int,
        application: UInt16 = 1,
        serverPublicKey: String,
        myPrivateKey: String
    ) {
        self.id = id
        self.name = name
        self.serverIP = serverIP
        self.serverPort = serverPort
        self.application = application
        self.serverPublicKey = serverPublicKey
        self.myPrivateKey = myPrivateKey
    }

    /// The core WireGuard `TesseraConfig` for this connection, or nil when the
    /// fields are incomplete/invalid (never configure a partial tunnel).
    public var tesseraConfig: TesseraConfig? {
        let ip = serverIP.trimmingCharacters(in: .whitespaces)
        let pub = serverPublicKey.trimmingCharacters(in: .whitespaces)
        let priv = myPrivateKey.trimmingCharacters(in: .whitespaces)
        guard !ip.isEmpty, !pub.isEmpty, !priv.isEmpty,
              serverPort > 0, serverPort <= 65535 else { return nil }
        return TesseraConfig(
            serverIP: ip,
            serverPort: serverPort,
            serverPublicKey: pub,
            myPrivateKey: priv,
            application: application
        )
    }

    public var endpointLabel: String {
        "\(serverIP.trimmingCharacters(in: .whitespaces)):\(serverPort)"
    }

    /// True when all fields needed to hand the relay a config are set.
    public var isComplete: Bool { tesseraConfig != nil }

    /// Short human-readable incompleteness note (for the picker rows).
    public var completenessNote: String? {
        if tesseraConfig != nil { return nil }
        var missing: [String] = []
        if serverIP.trimmingCharacters(in: .whitespaces).isEmpty { missing.append("server IP") }
        if serverPublicKey.trimmingCharacters(in: .whitespaces).isEmpty { missing.append("public key") }
        if myPrivateKey.trimmingCharacters(in: .whitespaces).isEmpty { missing.append("client private key") }
        return missing.isEmpty ? "incomplete" : "missing " + missing.joined(separator: ", ")
    }
}

/// The storage policy behind "Save and Connect".
///
/// Before this slice the handler only set an in-UI key, so the picker never
/// reached the daemon: a user who chose file storage kept getting Tessera
/// sessions from Telegram until they hand-edited `config.json`. Every pick now
/// becomes `storage.active` (and, for a saved connection, that connection's
/// `tessera` block) in **one** `ConfigurationStore.mutate`, which is the same
/// write path the CLI and the daemon read.
public enum StoragePolicy {

    /// Why a pick cannot be written. Every case leaves the previous policy in
    /// force: a failed write never half-applies a medium.
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// "Default (config.json)" picked while the file has no `tessera` block.
        case noTesseraBlock
        /// A connection whose fields cannot form a tunnel.
        case incompleteConnection

        public var description: String {
            switch self {
            case .noTesseraBlock:
                return "Default (config.json) has no tessera section — add one there or pick a connection."
            case .incompleteConnection:
                return "That Tessera storage connection is incomplete (server IP, port, public key and client private key are required)."
            }
        }
    }

    /// Apply `medium` to `config` in memory.
    ///
    /// Shared by the store path and a render fixture (which owns no file), so
    /// both apply exactly the same rules.
    ///
    /// - `"file"` → `storage.active = "file"`, keeping the `tessera` block: it
    ///   is a credential, not a switch.
    /// - `"config"` → `storage.active = "tessera"` for the block already in
    ///   `config.json`; an absent block is an error, not a silent file switch.
    /// - a connection id → that connection's tunnel **and** `storage.active`
    ///   together. `saveConfig` splits the private key into `.env`.
    public static func apply(
        _ config: inout ArcConfig,
        medium: String,
        connections: [TesseraStorageConnection]
    ) throws {
        switch medium {
        case StorageMedium.file.rawValue:
            config.storage.active = StorageMedium.file.rawValue
        case "config":
            guard config.tessera != nil else { throw Failure.noTesseraBlock }
            config.storage.active = StorageMedium.tessera.rawValue
        default:
            guard let connection = connections.first(where: { $0.id == medium }),
                  let tessera = connection.tesseraConfig else {
                throw Failure.incompleteConnection
            }
            config.tessera = tessera
            config.storage.active = StorageMedium.tessera.rawValue
        }
    }

    /// Persist `medium` through the store. Throws before the file is touched
    /// when the pick cannot be expressed, leaving the previous policy in force.
    @discardableResult
    public static func write(
        medium: String,
        connections: [TesseraStorageConnection],
        to store: ConfigurationStore
    ) async throws -> ConfigurationStore.Snapshot {
        try await store.mutate { config in
            try apply(&config, medium: medium, connections: connections)
        }
    }
}

/// The picker row that names a resolved medium: `"file"`, `"config"` (the
/// `tessera` block of `config.json`) or a saved connection id.
///
/// Matching is by endpoint identity — the client private key lives in `.env`,
/// so an exact `TesseraConfig` comparison would fail on the file's copy.
public func storageMediumID(
    for selection: StoreSelection,
    connections: [TesseraStorageConnection]
) -> String {
    guard selection.backend == .tessera, let tessera = selection.tessera else {
        return StorageMedium.file.rawValue
    }
    return connections.first {
        $0.tesseraConfig?.endpointIdentity == tessera.endpointIdentity
    }?.id ?? "config"
}


/// The global default context recipe persisted by the web UI's "Context" tab
/// (`contextDefaults` in `~/.arc-agent-webui/settings.json`). `ArcDaemon`
/// consults it at boot so a segment toggle made in the UI is the default the
/// whole process uses for new sessions on the next start — the choice is not
/// just cosmetic until a manual edit of `config.json`.
public struct WebUIContextDefaults: Sendable {
    /// Tolerant read of the `contextDefaults` key from the web UI settings file.
    /// Missing file or missing key returns nil (caller falls back to the CLI
    /// config defaults).
    public static func loadFromDisk() -> ContextRecipe? {
        let url = ArcHome.webUISettings
        return load(from: url)
    }

    /// Tolerant decode of the recipe from a settings file (the daemon reads
    /// `~/.arc-agent-webui/settings.json`; tests read temp files).
    public static func load(from url: URL) -> ContextRecipe? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        struct Box: Codable { var contextDefaults: ContextRecipe? }
        guard let box = try? JSONDecoder().decode(Box.self, from: data) else { return nil }
        return box.contextDefaults
    }
}
