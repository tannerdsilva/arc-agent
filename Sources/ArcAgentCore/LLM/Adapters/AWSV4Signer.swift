import Foundation
import CryptoKit
import AsyncHTTPClient

/// AWS Signature Version 4 request signer (pure Foundation + CryptoKit).
/// Mirrors the AWS SDK's SigV4 flow: canonical request → string-to-sign →
/// HMAC chain — enough for Bedrock Converse calls with static credentials
/// from environment (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` /
/// `AWS_REGION` or `AWS_DEFAULT_REGION`).
public struct AWSV4Signer: Sendable {
    public let accessKey: String
    public let secretKey: String
    public let region: String
    public let service: String

    public init(accessKey: String, secretKey: String, region: String, service: String = "bedrock") {
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.region = region
        self.service = service
    }

    /// Resolve credentials from the environment (Hermes
    /// `resolve_aws_auth_env_var` chain mirrors the shared credentials file
    /// lookup; env is the portable subset).
    public static func fromEnvironment() -> AWSV4Signer? {
        let env = ProcessInfo.processInfo.environment
        guard let access = env["AWS_ACCESS_KEY_ID"],
              let secret = env["AWS_SECRET_ACCESS_KEY"] else { return nil }
        let region = env["AWS_REGION"] ?? env["AWS_DEFAULT_REGION"] ?? "us-east-1"
        return AWSV4Signer(accessKey: access, secretKey: secret, region: region)
    }

    /// Sign a request: returns the `Authorization` header value plus the
    /// `X-Amz-Date` header that must accompany it.
    public func signedHeaders(
        method: String,
        url: URL,
        payload: Data,
        now: Date = Date()
    ) -> (authorization: String, date: String) {
        let amzDate = Self.formatAmazonDate(now, short: false)
        let dateStamp = Self.formatAmazonDate(now, short: true)

        let host = url.host ?? ""
        // Canonical URI must be the URL-encoded path (keep it simple: use the
        // path components percent-encoded form).
        let canonicalURI = url.path.isEmpty ? "/" : url.path
        let canonicalQuery = url.query ?? ""

        let payloadHash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()

        var headers: [(String, String)] = [
            ("content-type", "application/json"),
            ("host", host),
            ("x-amz-date", amzDate),
        ]
        headers.sort { $0.0 < $1.0 }
        let canonicalHeaders = headers
            .map { "\($0.0):\($0.1.trimmingCharacters(in: .whitespaces))" }
            .joined(separator: "\n") + "\n"
        let signedHeaderList = headers.map { $0.0 }.joined(separator: ";")

        let canonicalRequest = [
            method.uppercased(),
            canonicalURI,
            canonicalQuery,
            canonicalHeaders,
            signedHeaderList,
            payloadHash,
        ].joined(separator: "\n")

        let algorithm = "AWS4-HMAC-SHA256"
        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            algorithm,
            amzDate,
            credentialScope,
            SHA256.hash(data: Data(canonicalRequest.utf8)).map { String(format: "%02x", $0) }.joined(),
        ].joined(separator: "\n")

        let dateKey = Self.hmac(key: Data("AWS4\(secretKey)".utf8), data: Data(dateStamp.utf8))
        let dateRegionKey = Self.hmac(key: dateKey, data: Data(region.utf8))
        let dateRegionServiceKey = Self.hmac(key: dateRegionKey, data: Data(service.utf8))
        let signingKey = Self.hmac(key: dateRegionServiceKey, data: Data("aws4_request".utf8))
        let signature = Self.hmac(key: signingKey, data: Data(stringToSign.utf8))
            .map { String(format: "%02x", $0) }.joined()

        let authorization = "\(algorithm) Credential=\(accessKey)/\(credentialScope), SignedHeaders=\(signedHeaderList), Signature=\(signature)"
        return (authorization, amzDate)
    }

    static func hmac(key: Data, data: Data) -> Data {
        let keySym = SymmetricKey(data: key)
        return Data(HMAC<SHA256>.authenticationCode(for: data, using: keySym))
    }

    static func formatAmazonDate(_ date: Date, short: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = short ? "yyyyMMdd" : "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }
}
