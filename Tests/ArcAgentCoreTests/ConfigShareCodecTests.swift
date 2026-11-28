import Foundation
import Testing
import RAW_base64

@testable import ArcAgentCore

extension ArcCoreTestRoot {

    /// The `arc1e.` envelope: a passphrase-encrypted blob carrying one model
    /// configuration. These pin the properties the scheme claims — round-trip
    /// fidelity, that a wrong passphrase and a tampered blob are indistinguishable,
    /// and that the *header* is authenticated (the property that stops an attacker
    /// from rewriting the KDF cost down to a cheap setting).
    @Suite("config share codec", .serialized)
    struct ConfigShareCodecTests {

        private func payload(
            name: String = "deepseek-v4-flash",
            apiKey: String = "sk-test-0123456789abcdef",
            createdAt: String = "2026-11-27T12:00:00Z"
        ) -> ConfigSharePayload {
            ConfigSharePayload(
                preset: .init(
                    name: name,
                    model: "deepseek-v4-flash",
                    provider: "silva-quad",
                    baseURL: "https://api.example.com/v1",
                    apiKey: apiKey,
                    contextLength: 128_000,
                    maxOutputTokens: 8192,
                    temperature: 0.7,
                    topP: 0.95,
                    reasoningEffort: "medium",
                    compressionBudget: 32_000
                ),
                createdAt: createdAt
            )
        }

        // MARK: round trip

        @Test("a sealed payload opens to exactly what was sealed")
        func roundTrip() throws {
            let original = payload()
            let blob = try ConfigShareCodec.encode(original, password: "7xKq2mPz9T")
            let opened = try ConfigShareCodec.decode(blob, password: "7xKq2mPz9T")
            #expect(opened == original)
            // every field survives, including the key — that is the point of the
            // feature, and the reason the envelope is encrypted.
            #expect(opened.preset.apiKey == original.preset.apiKey)
            #expect(opened.preset.baseURL == original.preset.baseURL)
            #expect(opened.preset.compressionBudget == 32_000)
        }

        @Test("unset optionals stay unset across the round trip")
        func roundTripKeepsNil() throws {
            let sparse = ConfigSharePayload(
                preset: .init(
                    name: "bare",
                    model: "m",
                    provider: "custom",
                    baseURL: "https://x/v1",
                    apiKey: ""
                ),
                createdAt: "2026-11-27T00:00:00Z"
            )
            let blob = try ConfigShareCodec.encode(sparse, password: "password12")
            let opened = try ConfigShareCodec.decode(blob, password: "password12")
            #expect(opened == sparse)
            #expect(opened.preset.contextLength == nil)
            #expect(opened.preset.temperature == nil)
            #expect(opened.preset.reasoningEffort == nil)
        }

        @Test("the blob carries the arc1e prefix")
        func hasPrefix() throws {
            let blob = try ConfigShareCodec.encode(payload(), password: "password12")
            #expect(blob.hasPrefix("arc1e."))
        }

        @Test("the same payload sealed twice produces different blobs")
        func saltsAndNoncesAreRandom() throws {
            let original = payload()
            let a = try ConfigShareCodec.encode(original, password: "password12")
            let b = try ConfigShareCodec.encode(original, password: "password12")
            // a fresh salt and nonce every time: identical plaintext must not
            // produce an identical blob, or two shares reveal they carry the same
            // configuration.
            #expect(a != b)
            // both still open to the same plaintext.
            #expect(try ConfigShareCodec.decode(a, password: "password12") == original)
            #expect(try ConfigShareCodec.decode(b, password: "password12") == original)
        }

        // MARK: authentication

        @Test("a wrong passphrase fails authentication")
        func wrongPassword() throws {
            let blob = try ConfigShareCodec.encode(payload(), password: "correct1234")
            #expect(throws: ConfigShareError.authenticationFailed) {
                try ConfigShareCodec.decode(blob, password: "incorrect123")
            }
        }

        @Test("a wrong passphrase is indistinguishable from a corrupted blob")
        func wrongPasswordIsNotAnOracle() throws {
            let blob = try ConfigShareCodec.encode(payload(), password: "correct1234")
            // the same error for both, so an attacker learns nothing about which
            // they got wrong.
            let wrongPass = #expect(throws: ConfigShareError.self) {
                try ConfigShareCodec.decode(blob, password: "incorrect123")
            }
            // corrupt a real ciphertext byte. note: editing the final base64
            // CHARACTER is not a valid corruption — its low bits are padding and
            // the decoder ignores them, so the envelope decodes to identical
            // bytes. tamper inside the decoded envelope instead.
            var envelope = try decodeEnvelope(blob)
            envelope[76] ^= 0x01
            let corrupt = ConfigShareCodec.prefix + encodeEnvelope(envelope)
            let tampered = #expect(throws: ConfigShareError.self) {
                try ConfigShareCodec.decode(corrupt, password: "correct1234")
            }
            #expect(wrongPass == tampered)
        }

        @Test("a tampered ciphertext fails authentication")
        func tamperedCiphertext() throws {
            let blob = try ConfigShareCodec.encode(payload(), password: "password12")
            var envelope = try decodeEnvelope(blob)
            // the ciphertext starts at offset 76; flip a bit inside it.
            envelope[80] ^= 0x01
            let tampered = ConfigShareCodec.prefix + encodeEnvelope(envelope)
            #expect(throws: ConfigShareError.authenticationFailed) {
                try ConfigShareCodec.decode(tampered, password: "password12")
            }
        }

        @Test("a tampered tag fails authentication")
        func tamperedTag() throws {
            let blob = try ConfigShareCodec.encode(payload(), password: "password12")
            var envelope = try decodeEnvelope(blob)
            envelope[56] ^= 0x01   // first tag byte
            let tampered = ConfigShareCodec.prefix + encodeEnvelope(envelope)
            #expect(throws: ConfigShareError.authenticationFailed) {
                try ConfigShareCodec.decode(tampered, password: "password12")
            }
        }

        /// The load-bearing property of the design. The KDF cost fields live in the
        /// clear header, so an attacker CAN rewrite them — but the header is the
        /// AEAD's associated data, so the tag check fails. Without this binding a
        /// cheap-memory brute force would work while the blob still decrypted.
        @Test("a lowered KDF cost in the header fails authentication")
        func tamperedKDFCostFailsAuthentication() throws {
            let blob = try ConfigShareCodec.encode(payload(), password: "password12")
            var envelope = try decodeEnvelope(blob)
            // memoryCost is bytes 10..<14, big-endian. rewrite it to the minimum.
            envelope[10] = 0x00
            envelope[11] = 0x00
            envelope[12] = 0x00
            envelope[13] = 0x08   // 8 KiB
            let weakened = ConfigShareCodec.prefix + encodeEnvelope(envelope)
            #expect(throws: ConfigShareError.authenticationFailed) {
                try ConfigShareCodec.decode(weakened, password: "password12")
            }
        }

        @Test("a tampered salt fails authentication")
        func tamperedSalt() throws {
            let blob = try ConfigShareCodec.encode(payload(), password: "password12")
            var envelope = try decodeEnvelope(blob)
            envelope[16] ^= 0xFF   // first salt byte
            let tampered = ConfigShareCodec.prefix + encodeEnvelope(envelope)
            // a different salt derives a different key, so the tag fails.
            #expect(throws: ConfigShareError.authenticationFailed) {
                try ConfigShareCodec.decode(tampered, password: "password12")
            }
        }

        @Test("a tampered nonce fails authentication")
        func tamperedNonce() throws {
            let blob = try ConfigShareCodec.encode(payload(), password: "password12")
            var envelope = try decodeEnvelope(blob)
            envelope[32] ^= 0xFF   // first nonce byte
            let tampered = ConfigShareCodec.prefix + encodeEnvelope(envelope)
            #expect(throws: ConfigShareError.authenticationFailed) {
                try ConfigShareCodec.decode(tampered, password: "password12")
            }
        }

        // MARK: malformed input

        @Test("a blob without the prefix is refused")
        func badPrefix() {
            #expect(throws: ConfigShareError.badPrefix) {
                try ConfigShareCodec.decode("bm90LWEtYmxvYg", password: "password12")
            }
        }

        @Test("an unsupported envelope version is refused")
        func unsupportedVersion() throws {
            let blob = try ConfigShareCodec.encode(payload(), password: "password12")
            var envelope = try decodeEnvelope(blob)
            envelope[4] = 0x09
            let bad = ConfigShareCodec.prefix + encodeEnvelope(envelope)
            #expect(throws: ConfigShareError.unsupportedVersion(9)) {
                try ConfigShareCodec.decode(bad, password: "password12")
            }
        }

        @Test("invalid base64 is refused")
        func malformedBase64() {
            #expect(throws: ConfigShareError.malformedBase64) {
                try ConfigShareCodec.decode("arc1e.!!!!not-base64!!!!", password: "password12")
            }
        }

        @Test("a truncated envelope is refused")
        func truncated() throws {
            let blob = try ConfigShareCodec.encode(payload(), password: "password12")
            let envelope = try decodeEnvelope(blob)
            let truncatedBlob = ConfigShareCodec.prefix + encodeEnvelope(Array(envelope.prefix(40)))
            #expect(throws: ConfigShareError.malformedEnvelope) {
                try ConfigShareCodec.decode(truncatedBlob, password: "password12")
            }
        }

        @Test("trailing bytes after the ciphertext are refused")
        func spliced() throws {
            let blob = try ConfigShareCodec.encode(payload(), password: "password12")
            var envelope = try decodeEnvelope(blob)
            envelope.append(contentsOf: [0x00, 0x01, 0x02, 0x03])
            let splicedBlob = ConfigShareCodec.prefix + encodeEnvelope(envelope)
            // the length field still describes the real ciphertext, so a spliced
            // envelope is refused rather than silently truncated.
            #expect(throws: ConfigShareError.malformedEnvelope) {
                try ConfigShareCodec.decode(splicedBlob, password: "password12")
            }
        }

        @Test("a wrong magic is refused")
        func badMagic() throws {
            let blob = try ConfigShareCodec.encode(payload(), password: "password12")
            var envelope = try decodeEnvelope(blob)
            envelope[0] = 0x00
            let bad = ConfigShareCodec.prefix + encodeEnvelope(envelope)
            #expect(throws: ConfigShareError.malformedEnvelope) {
                try ConfigShareCodec.decode(bad, password: "password12")
            }
        }

        // MARK: passphrase generation

        @Test("a generated passphrase has the requested length and a safe alphabet")
        func generatedPassphraseShape() {
            let safe = Set("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
            for _ in 0..<50 {
                let pass = ConfigShareCodec.generatePassword()
                #expect(pass.count == 10)
                #expect(pass.allSatisfy { safe.contains($0) })
                // the four visually ambiguous characters are absent by construction.
                #expect(!pass.contains("0"))
                #expect(!pass.contains("O"))
                #expect(!pass.contains("I"))
                #expect(!pass.contains("l"))
            }
        }

        @Test("generated passphrases are distinct")
        func generatedPassphrasesAreDistinct() {
            // 10 chars over a 58-char alphabet: a collision across 200 draws would
            // mean the generator is not consuming entropy per character.
            let generated = (0..<200).map { _ in ConfigShareCodec.generatePassword() }
            #expect(Set(generated).count == 200)
        }

        @Test("a generated passphrase produces a blob it can open")
        func generatedPassphraseRoundTrips() throws {
            let pass = ConfigShareCodec.generatePassword()
            let original = payload()
            let blob = try ConfigShareCodec.encode(original, password: pass)
            #expect(try ConfigShareCodec.decode(blob, password: pass) == original)
        }

        // MARK: helpers

        /// Recover the raw envelope bytes from a blob, for the tamper tests.
        private func decodeEnvelope(_ blob: String) throws -> [UInt8] {
            let body = String(blob.dropFirst(ConfigShareCodec.prefix.count))
            var padded = body
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            while padded.count % 4 != 0 { padded += "=" }
            return [UInt8](try RAW_base64.decode(padded))
        }

        /// Re-encode raw envelope bytes the way the codec does, so the tamper tests
        /// exercise the real decode path.
        private func encodeEnvelope(_ bytes: [UInt8]) -> String {
            let encoded = RAW_base64.encode(bytes)
            var out = String()
            for value in encoded {
                out.unicodeScalars.append(UnicodeScalar(value.asciiValue()))
            }
            return out
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }
    }
}
