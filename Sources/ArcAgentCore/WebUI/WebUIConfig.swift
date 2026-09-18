import Foundation
import WebUIAuth

/// configuration for the web ui host served by the gateway.
public struct WebConfig: Codable, Sendable, Equatable {

	/// whether the web ui host runs at all (default true).
	public var enabled: Bool
	/// bind host for the web ui server (the rest api keeps its own port).
	public var host: String
	/// bind port for the web ui server.
	public var port: Int
	/// whether interactive pages require a login.
	public var authEnabled: Bool
	/// the login username.
	public var username: String
	/// the login password. empty on first run: the gateway generates a random
	/// one, prints it once, and persists only its argon2id hash. a plaintext
	/// override takes precedence over a stored hash and is never written back.
	public var password: String
	/// an argon2id password hash (phc `$argon2id$...`) used when `password` is
	/// empty; written back by the gateway after first-run generation.
	public var passwordHash: String
	/// hard cap on concurrent browser connections.
	public var maxConnections: Int

	public init(
		enabled: Bool = true,
		host: String = "127.0.0.1",
		port: Int = 8088,
		authEnabled: Bool = true,
		username: String = "admin",
		password: String = "",
		passwordHash: String = "",
		maxConnections: Int = 64
	) {
		self.enabled = enabled
		self.host = host
		self.port = port
		self.authEnabled = authEnabled
		self.username = username
		self.password = password
		self.passwordHash = passwordHash
		self.maxConnections = maxConnections
	}

	/// decode each field independently, defaulting any that are absent.
	public init(from decoder: any Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let d = WebConfig()
		self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
		self.host = try c.decodeIfPresent(String.self, forKey: .host) ?? d.host
		self.port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
		self.authEnabled = try c.decodeIfPresent(Bool.self, forKey: .authEnabled) ?? d.authEnabled
		self.username = try c.decodeIfPresent(String.self, forKey: .username) ?? d.username
		self.password = try c.decodeIfPresent(String.self, forKey: .password) ?? d.password
		self.passwordHash = try c.decodeIfPresent(String.self, forKey: .passwordHash) ?? d.passwordHash
		self.maxConnections = try c.decodeIfPresent(Int.self, forKey: .maxConnections) ?? d.maxConnections
	}
}

/// a fully-resolved authentication credential for the web ui host.
public struct WebUICredential: Sendable {
	/// the login username.
	public let username: String
	/// the argon2id password record used to verify logins.
	public let record: PasswordRecord
	/// a newly-generated plaintext password, printed once at startup. nil when
	/// the credential came from an existing hash or a configured password.
	public let generatedPassword: String?

	public init(username: String, record: PasswordRecord, generatedPassword: String?) {
		self.username = username
		self.record = record
		self.generatedPassword = generatedPassword
	}
}

extension WebConfig {
	/// resolve a login credential from the config, generating and persisting a
	/// random password on first run.
	/// - Parameters:
	///   - configURL: the config file to persist a generated hash into.
	/// - Returns: the resolved credential, or nil when auth is disabled.
	public func resolveCredential(persistingTo configURL: URL?) throws -> WebUICredential? {
		guard authEnabled else { return nil }

		// a plaintext override always wins (re-hashed; never stored).
		if !password.isEmpty {
			let salt = try PasswordVerifier.makeSalt()
			let hash = try PasswordVerifier.hash(
				password: [UInt8](password.utf8),
				salt: salt,
				parameters: .interactive
			)
			let record = PasswordRecord(salt: salt, hash: hash, parameters: .interactive)
			return WebUICredential(username: username, record: record, generatedPassword: nil)
		}

		// a stored phc hash is reused as-is.
		if !passwordHash.isEmpty, let record = try? PasswordRecord(encoded: passwordHash) {
			return WebUICredential(username: username, record: record, generatedPassword: nil)
		}

		// first run: generate a random password, persist only its hash, print
		// the plaintext once so the human can sign in.
		let generated = try Self.randomPassword()
		let salt = try PasswordVerifier.makeSalt()
		let hash = try PasswordVerifier.hash(
			password: [UInt8](generated.utf8),
			salt: salt,
			parameters: .interactive
		)
		let record = PasswordRecord(salt: salt, hash: hash, parameters: .interactive)
		var mutated = self
		mutated.passwordHash = record.encodedString()
		mutated.password = ""
		try WebConfig.persist(mutated, to: configURL)
		return WebUICredential(username: username, record: record, generatedPassword: generated)
	}

	/// a cryptographically-random 18-character password from the printable
	/// ascii band (no ambiguous characters). fails loud on entropy loss — no
	/// prng fallback.
	static func randomPassword() throws -> String {
		let alphabet = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789"
		guard let bytes = try? SessionToken.generate() else {
			throw SessionToken.TokenError.entropyUnavailable
		}
		return bytes.map { alphabet[alphabet.index(alphabet.startIndex, offsetBy: Int($0) % alphabet.count)] }.reduce("") { $0 + String($1) }
	}

	/// merge `web` into the on-disk config so a generated hash survives restarts.
	static func persist(_ web: WebConfig, to configURL: URL?) throws {
		let resolvedURL = configURL ?? FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent(".arc/config.json")
		var config = loadConfig(from: resolvedURL)
		config.web = web
		try saveConfig(config, to: resolvedURL)
	}
}
