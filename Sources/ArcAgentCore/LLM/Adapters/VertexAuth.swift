import Foundation
import Security

/// Google Cloud service-account → OAuth2 bearer token (Hermes
/// `vertex_adapter.py` auth path): build an RS256 JWT assertion, exchange it
/// at `token_uri`, and return the access token. Pure Foundation + Security.
public struct VertexAuth: Sendable {

    public struct ServiceAccount: Sendable {
        public let clientEmail: String
        public let privateKeyPEM: String
        public let tokenURI: String

        public init(clientEmail: String, privateKeyPEM: String, tokenURI: String = "https://oauth2.googleapis.com/token") {
            self.clientEmail = clientEmail
            self.privateKeyPEM = privateKeyPEM
            self.tokenURI = tokenURI
        }

        /// Parse a Google service-account JSON file (e.g. gcloud ADC).
        public static func fromJSON(_ data: Data) throws -> ServiceAccount {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw LLMError.decodingError("Vertex service-account file is not valid JSON")
            }
            guard let email = json["client_email"] as? String,
                  let key = json["private_key"] as? String else {
                throw LLMError.authenticationFailed
            }
            let tokenURI = json["token_uri"] as? String ?? "https://oauth2.googleapis.com/token"
            return ServiceAccount(clientEmail: email, privateKeyPEM: key, tokenURI: tokenURI)
        }
    }

    let account: ServiceAccount
    let scopes: [String]

    public init(account: ServiceAccount, scopes: [String] = ["https://www.googleapis.com/auth/cloud-platform"]) {
        self.account = account
        self.scopes = scopes
    }

    /// Fetch (and cache) an access token for the service account.
    public func accessToken() async throws -> String {
        let assertion = try buildAssertion()
        guard let url = URL(string: account.tokenURI) else { throw LLMError.networkError("Invalid token_uri") }
        let bodyString = "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=\(assertion)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(bodyString.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else {
            throw LLMError.authenticationFailed
        }
        return token
    }

    // MARK: - JWT assertion (RS256, Hermes `_build_jwt_assertion`)

    func buildAssertion() throws -> String {
        let now = Date()
        let header = ["alg": "RS256", "typ": "JWT"]
        let claims: [String: Any] = [
            "iss": account.clientEmail,
            "scope": scopes.joined(separator: " "),
            "aud": account.tokenURI,
            "iat": Int(now.timeIntervalSince1970),
            "exp": Int(now.timeIntervalSince1970) + 3600,
        ]
        let headerB64 = Self.base64URL(try JSONSerialization.data(withJSONObject: header))
        let claimsB64 = Self.base64URL(try JSONSerialization.data(withJSONObject: claims))
        let signingInput = "\(headerB64).\(claimsB64)"
        let signature = try Self.rsaSignSHA256(Data(signingInput.utf8), pem: account.privateKeyPEM)
        return "\(signingInput).\(signature)"
    }

    static func rsaSignSHA256(_ data: Data, pem: String) throws -> String {
        let keyData = try parsePEMPrivateKey(pem)
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        guard let secKey = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &error) else {
            throw LLMError.authenticationFailed
        }
        guard let signature = SecKeyCreateSignature(secKey, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, &error) else {
            throw LLMError.authenticationFailed
        }
        return base64URL(signature as Data)
    }

    static func parsePEMPrivateKey(_ pem: String) throws -> Data {
        let lines = pem.split(separator: "\n").map(String.init)
        let body = lines.filter { !$0.hasPrefix("-----") }.joined()
        guard let data = Data(base64Encoded: body) else {
            throw LLMError.authenticationFailed
        }
        return data
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
