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

/// Resolved storage selection — what ``ensureRuntime`` actually builds.
public struct StorageResolution: Equatable, Sendable {
    /// "file" | "tessera"
    public var backend: String
    /// The WireGuard config to connect (nil in file mode or when the
    /// selection could not be resolved).
    public var config: TesseraConfig?
    /// Human-readable medium label.
    public var label: String
}

/// Resolution rules for the storage-medium picker:
///
/// - "file"           → file store, always.
/// - "config"         → the `tessera` block of `~/.arc/config.json` if
///                      present, else file (bounded by `runtimeTesseraOff`).
/// - a connection id  → that connection's WireGuard config; an unknown or
///                      invalid id falls back to file (resilient, never nil).
public func resolveStorage(
    active: String,
    connections: [TesseraStorageConnection],
    cliTessera: TesseraConfig?
) -> StorageResolution {
    if active == "file" {
        return StorageResolution(backend: "file", config: nil, label: "Local file storage")
    }
    if active == "config" {
        if let t = cliTessera {
            return StorageResolution(
                backend: "tessera",
                config: t,
                label: "Tessera @ \(t.serverIP):\(t.serverPort) (config.json)"
            )
        }
        return StorageResolution(backend: "file", config: nil, label: "Local file storage")
    }
    if let conn = connections.first(where: { $0.id == active }), let cfg = conn.tesseraConfig {
        return StorageResolution(
            backend: "tessera",
            config: cfg,
            label: "Tessera @ \(conn.endpointLabel) (\(conn.name))"
        )
    }
    return StorageResolution(backend: "file", config: nil, label: "Local file storage")
}


// MARK: - Daemon-side storage selection

/// The storage selection persisted by the web UI's Settings → Storage picker
/// (`activeStorage` + `storageConnections` in `~/.arc-agent-webui/settings.json`).
/// `ArcDaemon` consults it at boot so a connection saved in the UI is the
/// storage the whole process (gateway + web UI) actually uses on the next
/// start — the selection is not just cosmetic until a manual switch.
public struct WebUIStorageSelection: Sendable {
    public var activeStorage: String
    public var connections: [TesseraStorageConnection]

    public init(activeStorage: String, connections: [TesseraStorageConnection]) {
        self.activeStorage = activeStorage
        self.connections = connections
    }

    /// Tolerant read of the picker's keys from the web UI settings file.
    /// Missing file or missing keys returns nil (caller falls back to the
    /// CLI config defaults).
    public static func loadFromDisk() -> WebUIStorageSelection? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".arc-agent-webui/settings.json")
        return load(from: url)
    }

    /// Tolerant decode of the picker's keys from a settings file (the daemon
    /// reads `~/.arc-agent-webui/settings.json`; tests read temp files).
    public static func load(from url: URL) -> WebUIStorageSelection? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        struct Box: Codable {
            var activeStorage: String?
            var storageConnections: [TesseraStorageConnection]?
        }
        guard let box = try? JSONDecoder().decode(Box.self, from: data) else { return nil }
        guard let active = box.activeStorage else { return nil }
        return WebUIStorageSelection(activeStorage: active, connections: box.storageConnections ?? [])
    }
}
