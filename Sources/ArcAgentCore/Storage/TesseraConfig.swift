import Foundation

/// Connection configuration for a Tessera storage server.
///
/// Tessera is a NOSTR event store reached over a WireGuard tunnel. Each
/// client has its own WireGuard key pair (transport identity) and derives its
/// NOSTR identity from the same private key, matching the server's
/// `create-unbounded-admin` registration. The application id scopes the
/// events this client writes to a single data domain on the server.
///
/// All storage written through ``TesseraConnection`` (sessions, memory,
/// profiles) is signed NOSTR events persisted into the server's LMDB backing
/// store.
public struct TesseraConfig: Codable, Sendable, Equatable {
    /// The server's IP address or hostname (the WireGuard peer).
    public var serverIP: String
    /// The server's WireGuard listening port.
    public var serverPort: Int
    /// The server's WireGuard public key, base64 (32 bytes decoded).
    public var serverPublicKey: String
    /// This client's WireGuard private key, base64 (32 bytes decoded).
    public var myPrivateKey: String
    /// The application id that scopes this client's events.
    public var application: UInt16

    public init(
        serverIP: String,
        serverPort: Int,
        serverPublicKey: String,
        myPrivateKey: String,
        application: UInt16 = 1
    ) {
        self.serverIP = serverIP
        self.serverPort = serverPort
        self.serverPublicKey = serverPublicKey
        self.myPrivateKey = myPrivateKey
        self.application = application
    }
}
