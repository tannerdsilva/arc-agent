import Foundation
import ArcAgentCore

/// A configured Tessera storage connection the user can switch to from
/// Settings → Storage. Persisted in `~/.arc-agent-webui/settings.json`
/// (`storageConnections`), independent of the CLI's `tessera` block in
/// `~/.arc/config.json` (which remains selectable as the "Default (config.json)"
/// medium).
struct TesseraStorageConnection: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var serverIP: String
    var serverPort: Int
    var application: UInt16
    var serverPublicKey: String
    var myPrivateKey: String

    init(
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
    var tesseraConfig: TesseraConfig? {
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

    var endpointLabel: String {
        "\(serverIP.trimmingCharacters(in: .whitespaces)):\(serverPort)"
    }
}

/// Resolved storage selection — what ``ensureRuntime`` actually builds.
struct StorageResolution: Equatable {
    /// "file" | "tessera"
    var backend: String
    /// The WireGuard config to connect (nil in file mode or when the
    /// selection could not be resolved).
    var config: TesseraConfig?
    /// Human-readable medium label.
    var label: String
}

/// Resolution rules for the storage-medium picker:
///
/// - "file"           → file store, always.
/// - "config"         → the `tessera` block of `~/.arc/config.json` if
///                      present, else file (bounded by `runtimeTesseraOff`).
/// - a connection id  → that connection's WireGuard config; an unknown or
///                      invalid id falls back to file (resilient, never nil).
func resolveStorage(
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
