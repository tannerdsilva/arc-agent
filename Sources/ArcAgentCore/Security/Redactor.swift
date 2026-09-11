import Foundation

// MARK: - Redaction (Hermes `redact.py` + `secret_scope.py`)

/// Secret detection + redaction, faithful to Hermes' pattern set:
/// known prefix patterns, key names in config/env/JSON/YAML, URL query and
/// userinfo components, JWTs, private keys, database connection strings, and
/// terminal output (env dumps).
public enum Redactor {

    /// Prefix patterns (Hermes `PREFIX_PATTERNS`): exact prefixes with
    /// plausible lengths (secrets are matched by their characteristic
    /// leading run).
    static let prefixPatterns: [(prefix: String, minLen: Int)] = [
        ("sk-", 20), ("sk-ant-", 20), ("sk-proj-", 20), ("sk-svcacct-", 20),
        ("ghp_", 36), ("github_pat_", 22), ("gho_", 36), ("ghu_", 36),
        ("ghs_", 36), ("ghr_", 36),
        ("xoxb-", 20), ("xoxp-", 20), ("xoxa-", 20), ("xoxr-", 20), ("xapp-", 24),
        ("AIza", 35),
        ("eyJ", 20), // JWT header
    ]

    /// Key names whose VALUES are always secrets (Hermes
    /// `is_known_secret_key`): when a config/env/JSON/YAML line contains
    /// `key: value` and the key matches, redact the value.
    static let knownSecretKeys: Set<String> = [
        "api_key", "apikey", "api-key", "apiToken", "api_token", "api-token",
        "token", "access_token", "accessToken", "refresh_token", "refreshToken",
        "secret", "client_secret", "clientSecret", "client_secret_id",
        "private_key", "privateKey", "private_key_id", "signing_key", "signingKey",
        "password", "passwd", "pwd", "passphrase",
        "authorization", "auth_token", "authToken", "bearer", "cookie",
        "aws_secret_access_key", "aws_access_key_id", "aws_session_token",
        "openai_api_key", "anthropic_api_key", "gemini_api_key",
        "connection_string", "connstr", "database_url", "db_url", "dsn",
        "webhook_secret", "webhook_secret_key", "session_id", "session_key",
        "credential", "credentials", "oauth_token", "id_token", "jwt", "sas_token",
    ]

    /// Substrings that indicate a value is a secret (Hermes
    /// `is_probably_secret_value`).
    static let secretValueMarkers = [
        "-----BEGIN", "PRIVATE KEY", "AKIA", "ASIA",
        "mongodb+srv://", "postgres://", "mysql://", "redis://",
        "amqp://", "Basic ", "Bearer ", "JWT ", "eyJ",
    ]

    // MARK: - Core API

    /// Redact all known secret shapes from free text (tool results, logs,
    /// model-visible content).
    public static func redact(_ text: String) -> String {
        var result = text
        result = redactKeyValuePairs(result)
        result = redactURLQuery(result)
        result = redactURLUserInfo(result)
        result = redactPEM(result)
        result = redactJWT(result)
        result = redactConnectionStrings(result)
        result = redactPrefixTokens(result)
        return result
    }

    /// Redact a terminal output block (env dumps: `export KEY=value` and
    /// `KEY=value` lines).
    public static func redactTerminalOutput(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var out: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // `export KEY=value` shell shape: strip the export keyword before
            // inspecting the key.
            let inspectable = trimmed.hasPrefix("export ")
                ? String(trimmed.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
                : trimmed
            if let eq = firstAssignment(inspectable) {
                let value = String(inspectable[eq...]).trimmingCharacters(in: .whitespaces)
                if isSecretValue(value) || keyLooksSecret(String(inspectable[..<eq])) {
                    out.append(String(inspectable[..<eq]) + "=[REDACTED]")
                    continue
                }
            }
            out.append(String(line))
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Key-shape helpers

    static func keyLooksSecret(_ key: String) -> Bool {
        let lower = key.lowercased().trimmingCharacters(in: .whitespaces)
        if knownSecretKeys.contains(lower) { return true }
        let core = lower.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
        return knownSecretKeys.contains { known in
            core.contains(known.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: ""))
        }
    }

    static func isSecretValue(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespaces)
        if v.isEmpty { return false }
        if prefixPatterns.contains(where: { v.hasPrefix($0.prefix) && v.count >= $0.minLen }) {
            return true
        }
        if v.count >= 24 && !v.contains(" ") { return keyStyleValue(v) }
        return secretValueMarkers.contains { v.contains($0) }
    }

    /// Long base64-ish/hex-ish runs (typical for API keys without prefixes).
    static func keyStyleValue(_ value: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-./+="))
        let chars = value.unicodeScalars
        guard chars.count >= 24 else { return false }
        let valid = chars.allSatisfy { allowed.contains($0) }
        let digits = chars.filter { CharacterSet.decimalDigits.contains($0) }.count
        return valid && digits >= 4
    }

    static func firstAssignment(_ line: String) -> String.Index? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let key = String(line[..<eq])
        guard key.rangeOfCharacter(from: CharacterSet(charactersIn: " ()[]{}$`\"")) == nil else { return nil }
        return eq
    }

    // MARK: - Rule renderers (NSRegularExpression; reversed application keeps
    // original ranges valid)

    static func replacingRegex(_ text: String, pattern: String,
                               replace: (_ match: NSTextCheckingResult, _ full: String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            let full = ns.substring(with: match.range)
            mutable.replaceCharacters(in: match.range, with: replace(match, full))
        }
        return mutable as String
    }

    static func captured(_ match: NSTextCheckingResult, _ text: NSString, _ group: Int) -> String {
        match.range(at: group).location == NSNotFound ? "" : text.substring(with: match.range(at: group))
    }

    static func redactKeyValuePairs(_ text: String) -> String {
        var result = text
        // Line-oriented env/config/YAML: KEY=value and KEY: value.
        let linePattern = #"^\s*([A-Za-z_][A-Za-z0-9_\-]*)\s*[:=]\s*(\S.*)$"#
        result = replacingRegex(result, pattern: linePattern) { match, _ in
            let ns = result as NSString
            let key = captured(match, ns, 1)
            let value = captured(match, ns, 2)
            if keyLooksSecret(key) {
                return "\(key) = [REDACTED]"
            }
            return ns.substring(with: match.range)
        }
        // JSON-style: "api_key": "value"
        let jsonPattern = #""([^"]{2,64})"\s*:\s*"([^"]{6,})""#
        result = replacingRegex(result, pattern: jsonPattern) { match, _ in
            let ns = result as NSString
            let key = captured(match, ns, 1)
            let value = captured(match, ns, 2)
            if keyLooksSecret(key) && !value.hasPrefix("[REDACTED") {
                return "\"\(key)\": \"[REDACTED]\""
            }
            return ns.substring(with: match.range)
        }
        return result
    }

    static func redactPrefixTokens(_ text: String) -> String {
        var result = text
        for (prefix, minLen) in prefixPatterns {
            var searchStart = result.startIndex
            while let range = result.range(of: prefix, range: searchStart..<result.endIndex) {
                var end = range.upperBound
                var count = 0
                while end < result.endIndex,
                      (result[end].isLetter || result[end].isNumber || result[end] == "_" || result[end] == "-"),
                      count < 128 {
                    end = result.index(after: end)
                    count += 1
                }
                if count >= minLen {
                    result.replaceSubrange(range.lowerBound..<end, with: "[REDACTED]")
                    searchStart = result.index(range.lowerBound, offsetBy: 10, limitedBy: result.endIndex) ?? result.endIndex
                } else {
                    searchStart = range.upperBound
                }
            }
        }
        return result
    }

    static func redactPEM(_ text: String) -> String {
        replacingRegex(text, pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#) { _, _ in
            "[REDACTED: private key]"
        }
    }

    static func redactJWT(_ text: String) -> String {
        replacingRegex(text, pattern: #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#) { _, _ in
            "[REDACTED: JWT]"
        }
    }

    static func redactConnectionStrings(_ text: String) -> String {
        replacingRegex(text, pattern: #"(mongodb(\+srv)?|postgres(ql)?|mysql|redis|amqp)://[^\s"']+"#) { match, _ in
            let ns = text as NSString
            let full = ns.substring(with: match.range)
            guard let scheme = full.split(separator: ":").first else { return full }
            return "\(scheme)://[REDACTED]"
        }
    }

    static func redactURLQuery(_ text: String) -> String {
        replacingRegex(text, pattern: #"([?&])([A-Za-z0-9_\-]+)=([^&\s"']+)"#) { match, _ in
            let ns = text as NSString
            let key = captured(match, ns, 2)
            if keyLooksSecret(key) {
                return "\(captured(match, ns, 1))\(key)=[REDACTED]"
            }
            return ns.substring(with: match.range)
        }
    }

    static func redactURLUserInfo(_ text: String) -> String {
        replacingRegex(text, pattern: #"(https?://)([^/@\s:]+):([^/@\s]+)@"#) { match, _ in
            let ns = text as NSString
            return "\(captured(match, ns, 1))[REDACTED]@"
        }
    }
}

// MARK: - Secret scope (Hermes `secret_scope.py`)

/// Per-profile secret scoping: which environment variable names are treated
/// as secrets globally vs per profile, and prefix rules.
public struct SecretScope: Sendable {
    public let profile: String
    /// Exact env names considered secrets (Hermes global env key list).
    public let globalEnvSecrets: [String]
    /// Prefix rules: env names starting with these are secrets.
    public let globalEnvPrefixes: [String]

    public init(profile: String,
                globalEnvSecrets: [String] = Redactor.defaultGlobalEnvSecrets,
                globalEnvPrefixes: [String] = []) {
        self.profile = profile
        self.globalEnvSecrets = globalEnvSecrets
        self.globalEnvPrefixes = globalEnvPrefixes
    }

    public func isSecretEnvVar(_ name: String) -> Bool {
        if globalEnvSecrets.contains(name) { return true }
        return globalEnvPrefixes.contains { name.hasPrefix($0) }
    }

    /// The scope label used in redaction logs (Hermes leaks the profile name
    /// into the scope header).
    public var scopeLabel: String { "profile:\(profile)" }
}

extension Redactor {
    /// Env var names always treated as secrets (Hermes global secrets list).
    public static let defaultGlobalEnvSecrets: [String] = [
        "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY",
        "OPENROUTER_API_KEY", "DEEPSEEK_API_KEY", "XAI_API_KEY", "MISTRAL_API_KEY",
        "GROQ_API_KEY", "TOGETHER_API_KEY", "FIREWORKS_API_KEY",
        "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
        "AZURE_OPENAI_API_KEY", "HF_TOKEN", "HUGGINGFACE_TOKEN",
        "GITHUB_TOKEN", "GH_TOKEN", "GITLAB_TOKEN", "PAT", "TOKEN",
        "PGPASSWORD", "DATABASE_URL", "DATABASE_PASSWORD", "DB_PASSWORD",
        "STRIPE_SECRET_KEY", "STRIPE_API_KEY", "TESSERA_KEY", "ARC_API_KEY",
    ]
}
