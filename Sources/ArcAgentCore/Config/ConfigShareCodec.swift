import Foundation
import RAW
import RAW_argon2
import RAW_base64
// `RAW_xchachapoly` re-exports the AEAD context and nonce but not the key or tag
// types: `Key` is a typealias for `RAW_chachapoly.Key32`, and `Tag` is
// `RAW_chachapoly.Tag`. rawdog's own tests import both modules for this reason.
import RAW_chachapoly
import RAW_xchachapoly

// MARK: - payload

/// The plaintext a config-share blob carries: one model configuration, including
/// its API key.
///
/// This is deliberately the smallest useful unit — a *single* preset, matching
/// the row-level share control. A whole-settings export would have to drag in
/// view state (`theme`, `workspaces` paths that are meaningless on the friend's
/// machine) and the auxiliary routing map, whose entries name presets that may
/// not travel with it. One preset is self-contained and unambiguous.
///
/// `source` is deliberately absent. Provenance is a local fact: a preset that
/// arrives from a friend becomes a UI-owned configuration (`source == "ui"`) on
/// import, because it did not come from this machine's `config.json`. Importing
/// it as the managed preset would make the next boot's reconcile silently
/// overwrite it from a config block the friend never had.
public struct ConfigSharePayload: Codable, Equatable, Sendable {

    /// One model configuration, field-for-field with the UI's `ModelConfigPreset`
    /// minus `source`. Every optional is carried as an optional so "unset" and
    /// "set to zero" cannot be confused on the other side.
    public struct Preset: Codable, Equatable, Sendable {
        public var name: String
        public var model: String
        public var provider: String
        public var baseURL: String
        public var apiKey: String
        public var contextLength: Int?
        public var maxOutputTokens: Int?
        public var temperature: Double?
        public var topP: Double?
        public var reasoningEffort: String?
        public var compressionBudget: Int?

        public init(
            name: String,
            model: String,
            provider: String,
            baseURL: String,
            apiKey: String,
            contextLength: Int? = nil,
            maxOutputTokens: Int? = nil,
            temperature: Double? = nil,
            topP: Double? = nil,
            reasoningEffort: String? = nil,
            compressionBudget: Int? = nil
        ) {
            self.name = name
            self.model = model
            self.provider = provider
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.contextLength = contextLength
            self.maxOutputTokens = maxOutputTokens
            self.temperature = temperature
            self.topP = topP
            self.reasoningEffort = reasoningEffort
            self.compressionBudget = compressionBudget
        }
    }

    /// Payload schema version. Bumped when the JSON shape changes; independent of
    /// the envelope version, which is bumped when the crypto framing changes.
    public var v: Int
    public var preset: Preset
    /// ISO-8601 creation time. Carried *inside* the ciphertext on purpose: a
    /// timestamp in the clear header would leak when a share was made.
    public var createdAt: String

    public init(v: Int = 1, preset: Preset, createdAt: String) {
        self.v = v
        self.preset = preset
        self.createdAt = createdAt
    }
}

// MARK: - offloading

/// The executor the Argon2 derivation runs on.
///
/// ``ConfigShareCodec``'s derive step is deliberately memory-hard — 64 MiB and
/// three passes — and measures at **~0.8 s** on this hardware, not the ~0.15 s a
/// naive estimate suggests (measured: the tamper tests, which derive twice,
/// report 1.60 s against 0.001 s for the paths that skip derivation). Running
/// that inline in a `@Wired` handler would occupy a cooperative thread for most
/// of a second and stall every concurrent streaming session on the same pool.
///
/// `Task.detached` does **not** solve this: a detached task still runs on the
/// cooperative pool, so a synchronous 0.8 s block starves a pool thread either
/// way. The only fix is to move the work to a thread the pool does not own —
/// which is what this actor's serial executor is for.
///
/// This is a deliberate, narrow exception to the First Law's "no dispatch
/// queues" rule, in the same spirit as the accepted Tessera/storage exceptions:
/// a queue used *specifically* so that blocking work never touches the
/// cooperative pool. It is the only such use in the config subsystem, and no
/// other work is ever scheduled on it.
actor ConfigShareExecutor {
    /// The process-wide instance; the work is rare (a user clicks Share) so one
    /// thread is plenty, and serialising the KDF caps peak memory at one 64 MiB
    /// derivation at a time.
    static let shared = ConfigShareExecutor()

    /// A dedicated serial queue as the actor's executor. `DispatchSerialQueue`
    /// is the standard-library-supported way to give an actor a real thread.
    private let queue = DispatchSerialQueue(label: "arc.config-share.kdf")

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }
}

// MARK: - async facade

extension ConfigShareCodec {

    /// Seal `payload` off the cooperative pool. See ``ConfigShareExecutor`` for
    /// why the derivation cannot run inline.
    public static func encodeOffPool(
        _ payload: ConfigSharePayload,
        password: String
    ) async throws -> String {
        try await ConfigShareExecutor.shared.seal(payload, password: password)
    }

    /// Open `blob` off the cooperative pool.
    public static func decodeOffPool(
        _ blob: String,
        password: String
    ) async throws -> ConfigSharePayload {
        try await ConfigShareExecutor.shared.open(blob, password: password)
    }
}

extension ConfigShareExecutor {

    /// Runs on the executor's own thread; the blocking derivation happens here.
    fileprivate func seal(
        _ payload: ConfigSharePayload,
        password: String
    ) throws -> String {
        try ConfigShareCodec.encode(payload, password: password)
    }

    /// Runs on the executor's own thread.
    fileprivate func open(
        _ blob: String,
        password: String
    ) throws -> ConfigSharePayload {
        try ConfigShareCodec.decode(blob, password: password)
    }
}

// MARK: - errors

/// Every way a share can fail to encode or decode.
///
/// `authenticationFailed` deliberately collapses "wrong password" and
/// "tampered/corrupt blob" into one case. Distinguishing them would hand an
/// attacker a validation oracle: they could tell a corrupted blob from a
/// wrong-password guess without knowing the password.
/// `RAW_base64` and `RAW_argon2` each export a type literally named `Error`, which
/// shadows `Swift.Error` inside this file. Every conformance below is therefore
/// spelled `Swift.Error` rather than `Error`.
public enum ConfigShareError: Swift.Error, Equatable {

    /// The blob does not begin with `arc1e.`.
    case badPrefix
    /// The envelope version or KDF id is not one this build understands.
    case unsupportedVersion(UInt8)
    /// A fixed section is the wrong size, or a length field overruns the buffer.
    case malformedEnvelope
    /// The base64 tail is not valid base64url.
    case malformedBase64
    /// The AEAD tag did not verify — wrong password, or the header/ciphertext was
    /// altered. One case on purpose; see the type's note.
    case authenticationFailed
    /// The decrypted bytes are not the JSON this version expects.
    case malformedPayload
    /// The decoded payload's `v` is not one this build understands.
    case unsupportedPayloadVersion(Int)
}

// MARK: - codec

/// `arc1e.` — a passphrase-encrypted, self-contained blob carrying one model
/// configuration so it can be handed to another arc instance.
///
/// The scheme, in order:
///
/// 1. the payload is encoded as canonical JSON (sorted keys, no whitespace) so
///    the same configuration always produces the same plaintext;
/// 2. Argon2id derives a 32-byte key from the passphrase and a random 16-byte
///    salt, at 64 MiB / 3 iterations / 1 lane;
/// 3. XChaCha20-Poly1305 seals the JSON under that key with a random 24-byte
///    nonce, authenticating the *header* as associated data;
/// 4. the assembled binary envelope is base64url-encoded (unpadded) behind the
///    `arc1e.` prefix.
///
/// Authenticating the header is the load-bearing part. Without it an attacker
/// could rewrite the KDF cost fields down to a trivial setting and attack the
/// passphrase cheaply — the ciphertext would still decrypt, because the key
/// would simply have been derived with the weakened parameters. Binding the
/// header to the tag makes any parameter edit fail the tag check.
///
/// The binary envelope (all integers big-endian):
///
/// ```
/// offset  size  field
/// 0       4     magic "ARC1"
/// 4       1     envelope version (1)
/// 5       1     kdf id (1 = argon2id)
/// 6       4     timeCost
/// 10      4     memoryCost (KiB)
/// 14      1     parallelism
/// 15      1     salt length (16)
/// 16      16    salt
/// 32      24    nonce
/// 56      16    tag          <- end of associated data
/// 72      4     ciphertext length
/// 76      n     ciphertext
/// ```
public enum ConfigShareCodec {

    /// The greppable prefix. Versioned independently of the payload schema so a
    /// future framing change can coexist with old blobs.
    public static let prefix = "arc1e."

    /// Envelope version this build writes and accepts.
    public static let envelopeVersion: UInt8 = 1

    /// Payload schema version this build writes and accepts.
    public static let payloadVersion = 1

    // KDF cost. These are also written into the envelope, so a reader uses the
    // costs the writer chose rather than whatever this build defaults to — old
    // blobs stay readable after a cost bump.
    private static let kdfID: UInt8 = 1
    private static let timeCost: UInt32 = 3
    private static let memoryCost: UInt32 = 65536   // KiB = 64 MiB
    private static let parallelism: UInt32 = 1
    private static let saltLength = 16
    private static let nonceLength = 24
    private static let tagLength = 16

    /// Bytes 0..<56 of the envelope: everything that must not be tampered with.
    private static let authenticatedHeaderLength = 56

    /// Bytes 0..<72: the authenticated header plus the tag itself.
    private static let headerLength = 72

    // MARK: encode

    /// Seal `payload` under `password`, returning a complete `arc1e.…` blob.
    ///
    /// The passphrase is used verbatim (no trimming/normalisation here) so that
    /// encoding is a pure function of its inputs; a caller accepting typed or
    /// pasted input normalises before calling.
    public static func encode(_ payload: ConfigSharePayload, password: String) throws -> String {
        let plaintext = try canonicalJSON(payload)

        let salt = randomBytes(saltLength)
        let nonceBytes = randomBytes(nonceLength)

        let key = try deriveKey(password: password, salt: salt)
        let nonce = nonceBytes.withUnsafeBytes { RAW_xchachapoly.Nonce(RAW_decode: $0)! }

        // the header is assembled before sealing because it is the AAD, and the
        // tag is appended afterwards at offset 56.
        var header = [UInt8]()
        header.reserveCapacity(headerLength)
        header.append(contentsOf: [0x41, 0x52, 0x43, 0x31])   // "ARC1"
        header.append(envelopeVersion)
        header.append(kdfID)
        header.append(contentsOf: bigEndian(timeCost))
        header.append(contentsOf: bigEndian(memoryCost))
        header.append(UInt8(parallelism))
        header.append(UInt8(saltLength))
        header.append(contentsOf: salt)
        header.append(contentsOf: nonceBytes)

        let ciphertext = try seal(plaintext, key: key, nonce: nonce, aad: header, tagOut: &header)

        var envelope = [UInt8]()
        envelope.reserveCapacity(headerLength + 4 + ciphertext.count)
        envelope.append(contentsOf: header)
        envelope.append(contentsOf: bigEndian(UInt32(ciphertext.count)))
        envelope.append(contentsOf: ciphertext)

        return prefix + base64urlEncode(envelope)
    }

    // MARK: decode

    /// Open an `arc1e.…` blob. Throws ``ConfigShareError`` on every failure path;
    /// a wrong passphrase surfaces as ``ConfigShareError/authenticationFailed``.
    public static func decode(_ blob: String, password: String) throws -> ConfigSharePayload {
        let trimmed = blob.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { throw ConfigShareError.badPrefix }
        let body = String(trimmed.dropFirst(prefix.count))

        let envelope: [UInt8]
        do {
            envelope = try base64urlDecode(body)
        } catch {
            throw ConfigShareError.malformedBase64
        }

        guard envelope.count >= headerLength + 4 else { throw ConfigShareError.malformedEnvelope }
        guard Array(envelope[0..<4]) == [0x41, 0x52, 0x43, 0x31] else {
            throw ConfigShareError.malformedEnvelope
        }

        let version = envelope[4]
        guard version == envelopeVersion else { throw ConfigShareError.unsupportedVersion(version) }
        let kdf = envelope[5]
        guard kdf == kdfID else { throw ConfigShareError.unsupportedVersion(kdf) }

        let timeCost = readBigEndian(envelope[6..<10])
        let memoryCost = readBigEndian(envelope[10..<14])
        let parallelism = UInt32(envelope[14])
        let saltLen = Int(envelope[15])
        guard saltLen == saltLength else { throw ConfigShareError.malformedEnvelope }

        let salt = Array(envelope[16..<32])
        let nonceBytes = Array(envelope[32..<56])
        let tagBytes = Array(envelope[56..<72])
        let ciphertextLength = Int(readBigEndian(envelope[72..<76]))

        let ciphertextStart = 76
        guard envelope.count >= ciphertextStart + ciphertextLength else {
            throw ConfigShareError.malformedEnvelope
        }
        let ciphertext = Array(envelope[ciphertextStart..<(ciphertextStart + ciphertextLength)])
        // trailing bytes mean the blob was spliced; refuse rather than ignore.
        guard envelope.count == ciphertextStart + ciphertextLength else {
            throw ConfigShareError.malformedEnvelope
        }

        // the costs come from the envelope, not from this build's defaults, so a
        // blob written before a cost bump stays readable. they are authenticated,
        // so a lowered cost means a failed tag, not a cheap attack.
        let key = try deriveKey(
            password: password,
            salt: salt,
            timeCost: timeCost,
            memoryCost: memoryCost,
            parallelism: parallelism
        )
        let nonce = nonceBytes.withUnsafeBytes { RAW_xchachapoly.Nonce(RAW_decode: $0)! }
        guard let tag = tagBytes.withUnsafeBytes({ RAW_chachapoly.Tag(RAW_decode: $0) }) else {
            throw ConfigShareError.malformedEnvelope
        }
        let aad = Array(envelope[0..<authenticatedHeaderLength])

        let plaintext = try open(ciphertext, key: key, nonce: nonce, aad: aad, tag: tag)

        let payload: ConfigSharePayload
        do {
            payload = try JSONDecoder().decode(ConfigSharePayload.self, from: Data(plaintext))
        } catch {
            throw ConfigShareError.malformedPayload
        }
        guard payload.v == payloadVersion else {
            throw ConfigShareError.unsupportedPayloadVersion(payload.v)
        }
        return payload
    }

    // MARK: passphrase

    /// The unambiguous base58 alphabet: no `0`, `O`, `I` or `l`, so a passphrase
    /// dictated over a call or retyped from a screen cannot be mistyped as a
    /// different character that looks the same.
    static let passphraseAlphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    /// Generate a passphrase from the CSPRNG with rejection sampling.
    ///
    /// Rejection (rather than `% 58`) matters: 256 is not a multiple of 58, so a
    /// plain modulo would make the first 24 letters of the alphabet measurably
    /// more likely than the rest, silently shrinking the keyspace.
    public static func generatePassword(length: Int = 10) -> String {
        precondition(length > 0, "passphrase length must be positive")
        let alphabet = passphraseAlphabet
        let limit = UInt8(256 - (256 % alphabet.count))   // largest unbiased bound
        var rng = SystemRandomNumberGenerator()
        var out = [Character]()
        out.reserveCapacity(length)
        while out.count < length {
            let byte = UInt8.random(in: .min ... .max, using: &rng)
            guard byte < limit else { continue }
            out.append(alphabet[Int(byte) % alphabet.count])
        }
        return String(out)
    }

    // MARK: crypto primitives

    /// argon2id → a 32-byte XChaCha20-Poly1305 key.
    ///
    /// This is deliberately CPU- and memory-hard: it is the only thing standing
    /// between a short passphrase and an offline attacker. It *blocks* for
    /// roughly a tenth of a second, so callers on an async executor must not run
    /// it inline — see ``ConfigShareCodec/encode(_:password:)``'s callers.
    private static func deriveKey(
        password: String,
        salt: [UInt8],
        timeCost: UInt32 = ConfigShareCodec.timeCost,
        memoryCost: UInt32 = ConfigShareCodec.memoryCost,
        parallelism: UInt32 = ConfigShareCodec.parallelism
    ) throws -> RAW_chachapoly.Key32 {
        let passwordBytes = Array(password.utf8)
        return try RAW_argon2.ID.hash(
            password: passwordBytes,
            salt: salt,
            timeCost: timeCost,
            memoryCost: memoryCost,
            parallelism: parallelism,
            as: RAW_chachapoly.Key32.self
        )
    }

    private static func seal(
        _ plaintext: [UInt8],
        key: RAW_chachapoly.Key32,
        nonce: RAW_xchachapoly.Nonce,
        aad: [UInt8],
        tagOut header: inout [UInt8]
    ) throws -> [UInt8] {
        var context = RAW_xchachapoly.Context(key: key)
        var ciphertext = [UInt8](repeating: 0, count: plaintext.count)
        let tag = try plaintext.withUnsafeBufferPointer { input in
            try aad.withUnsafeBufferPointer { associated in
                try ciphertext.withUnsafeMutableBufferPointer { output in
                    try context.encrypt(
                        nonce: nonce,
                        associatedData: associated,
                        inputData: input,
                        output: output.baseAddress!
                    )
                }
            }
        }
        header.append(contentsOf: tag.RAW_access_immutable(UnsafeRawBufferPointer.self) { Array($0) })
        return ciphertext
    }

    private static func open(
        _ ciphertext: [UInt8],
        key: RAW_chachapoly.Key32,
        nonce: RAW_xchachapoly.Nonce,
        aad: [UInt8],
        tag: RAW_chachapoly.Tag
    ) throws -> [UInt8] {
        var context = RAW_xchachapoly.Context(key: key)
        var plaintext = [UInt8](repeating: 0, count: ciphertext.count)
        do {
            try ciphertext.withUnsafeBufferPointer { input in
                try aad.withUnsafeBufferPointer { associated in
                    try plaintext.withUnsafeMutableBufferPointer { output in
                        try context.decrypt(
                            tag: tag,
                            nonce: nonce,
                            associatedData: associated,
                            inputData: input,
                            output: output.baseAddress!
                        )
                    }
                }
            }
        } catch {
            // the only failure the AEAD reports is a MAC mismatch.
            throw ConfigShareError.authenticationFailed
        }
        return plaintext
    }

    // MARK: encoding helpers

    /// Canonical JSON: sorted keys, no whitespace, so identical payloads produce
    /// byte-identical plaintext (and therefore comparable blobs under test).
    private static func canonicalJSON(_ payload: ConfigSharePayload) throws -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            return Array(try encoder.encode(payload))
        } catch {
            throw ConfigShareError.malformedPayload
        }
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        var rng = SystemRandomNumberGenerator()
        var out = [UInt8]()
        out.reserveCapacity(count)
        while out.count < count {
            let word = UInt64.random(in: .min ... .max, using: &rng)
            withUnsafeBytes(of: word) { out.append(contentsOf: $0) }
        }
        return Array(out.prefix(count))
    }

    /// `RAW_base64` writes the standard alphabet and omits padding. The blob is
    /// URL-safe and paste-safe, so `+`/`/` are folded to `-`/`_` here; the
    /// decoder reverses it and restores padding, which `RAW_base64` requires.
    private static func base64urlEncode(_ bytes: [UInt8]) -> String {
        let encoded = RAW_base64.encode(bytes)
        var out = String()
        out.reserveCapacity(encoded.unpaddedEncodedByteCount())
        for value in encoded {
            out.unicodeScalars.append(UnicodeScalar(value.asciiValue()))
        }
        return out
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    private static func base64urlDecode(_ string: String) throws -> [UInt8] {
        var padded = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        do {
            return try RAW_base64.decode(padded)
        } catch {
            throw ConfigShareError.malformedBase64
        }
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
    }

    private static func readBigEndian(_ slice: ArraySlice<UInt8>) -> UInt32 {
        var value: UInt32 = 0
        for byte in slice { value = (value << 8) | UInt32(byte) }
        return value
    }
}
