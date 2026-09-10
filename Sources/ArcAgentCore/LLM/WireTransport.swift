import Foundation
import AsyncHTTPClient
import NIO

/// Shared HTTP POST helper for provider adapters: builds the request,
/// executes, collects the body, and classifies non-2xx failures into
/// `LLMError`s — including provider-specific status codes (429/529/503…)
/// and body-pattern detection (Anthropic error objects, Google quota,
/// AWS throttling). Also captures rate-limit headers (Hermes
/// rate_limit_tracker input; the capture point lives with the network
/// boundary).
public struct WireTransport: Sendable {
    public let httpClient: HTTPClient
    public let defaultTimeoutSeconds: Double

    public init(httpClient: HTTPClient, defaultTimeoutSeconds: Double = 120) {
        self.httpClient = httpClient
        self.defaultTimeoutSeconds = defaultTimeoutSeconds
    }

    /// Raw response + captured rate-limit headers.
    public struct WireResponse: Sendable {
        public let status: Int
        public let headers: [String: String]
        public let body: Data
        public let retryAfter: Int?
        public let rateLimit: RateLimitSnapshot?
    }

    public struct RateLimitSnapshot: Sendable {
        public let limit: Int?
        public let remaining: Int?
        public let resetSeconds: Double?
        public let resetAt: Date?
        public let usedPercent: Double?
    }

    /// Execute a POST with the given JSON body; returns 2xx payload or throws
    /// a classified `LLMError`. `expectedStatusCodes` lets adapters accept
    /// e.g. 200-only responses for non-stream paths.
    public func post(
        url: String,
        headers: [String: String],
        body: Data,
        timeout: Double? = nil,
        accepted: ClosedRange<Int> = 200...299
    ) async throws -> WireResponse {
        var request = HTTPClientRequest(url: url)
        request.method = .POST
        for (k, v) in headers { request.headers.add(name: k, value: v) }
        request.body = .bytes(body)

        let response: HTTPClientResponse
        do {
            response = try await httpClient.execute(request, timeout: .seconds(Int64(timeout ?? defaultTimeoutSeconds)))
        } catch {
            throw LLMError.networkError(String(describing: error))
        }

        var collected = Data()
        if response.status.code != 204 {
            for try await chunk in response.body {
                collected.append(contentsOf: chunk.readableBytesView)
            }
        }

        var headersLower: [String: String] = [:]
        for (name, value) in response.headers {
            headersLower[name.lowercased()] = value
        }

        let retryAfter = Self.parseRetryAfter(headersLower["retry-after"])
        let rateLimit = Self.captureRateLimit(headers: headersLower)

        guard accepted.contains(Int(response.status.code)) else {
            throw Self.classifyError(
                status: Int(response.status.code),
                body: collected,
                headers: headersLower,
                retryAfter: retryAfter
            )
        }
        return WireResponse(
            status: Int(response.status.code),
            headers: headersLower,
            body: collected,
            retryAfter: retryAfter,
            rateLimit: rateLimit
        )
    }

    // MARK: - Error classification (Hermes error_classifier family mapping)

    public static func classifyError(
        status: Int,
        body: Data,
        headers: [String: String],
        retryAfter: Int?
    ) -> LLMError {
        let text = String(data: body, encoding: .utf8) ?? ""
        let lower = text.lowercased()

        switch status {
        case 401, 403:
            return .authenticationFailed
        case 402:
            return .apiError(statusCode: 402, message: text.isEmpty ? "Billing required" : text)
        case 408:
            return .timeout(1)
        case 409:
            return .apiError(statusCode: 409, message: text)
        case 429:
            return .rateLimited(retryAfter: retryAfter ?? 30)
        case 529:
            // Anthropic/OpenRouter overload marker
            return .apiError(statusCode: 529, message: text.isEmpty ? "Provider overloaded" : text)
        case 500, 502, 503:
            return .apiError(statusCode: status, message: text.isEmpty ? "Server error" : text)
        case 400:
            if lower.contains("context_length")
                || lower.contains("maximum context")
                || lower.contains("token limit")
                || lower.contains("context window")
                || lower.contains("too many tokens") {
                return .contextLengthExceeded(limit: extractContextLimit(from: text))
            }
            if lower.contains("content_filter") || lower.contains("content_policy")
                || lower.contains("safety") || lower.contains("blocked") {
                return .contentPolicyViolation(text)
            }
            // Anthropic error object: {"type":"error","error":{"type":"..."}}
            if lower.contains("\"error\"") {
                let errType = extractJSONStringField(text, key: "type")
                if errType.contains("invalid") && lower.contains("max_tokens") {
                    return .apiError(statusCode: 400, message: text)
                }
            }
            return .apiError(statusCode: 400, message: text)
        default:
            return .apiError(statusCode: status, message: text.isEmpty ? "HTTP \(status)" : text)
        }
    }

    /// Parse `Retry-After` (seconds or HTTP-date) — Hermes
    /// `parse_retry_after_seconds`.
    public static func parseRetryAfter(_ value: String?) -> Int? {
        guard let value = value, !value.isEmpty else { return nil }
        if let seconds = Int(value), seconds >= 0 { return seconds }
        // HTTP-date
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        formatter.timeZone = TimeZone(identifier: "GMT")
        if let date = formatter.date(from: value) {
            return max(0, Int(date.timeIntervalSinceNow.rounded()))
        }
        return nil
    }

    /// Capture `x-ratelimit-*` bucket data (OpenAI/Anthropic/OpenRouter style).
    public static func captureRateLimit(headers: [String: String]) -> RateLimitSnapshot? {
        let limit = Int(headers["x-ratelimit-limit-requests"] ?? headers["x-ratelimit-limit"] ?? "")
        let remaining = Int(headers["x-ratelimit-remaining-requests"] ?? headers["x-ratelimit-remaining"] ?? "")
        var resetSeconds: Double?
        var resetAt: Date?
        if let raw = headers["x-ratelimit-reset-requests"] ?? headers["x-ratelimit-reset"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            formatter.timeZone = TimeZone(identifier: "GMT")
            if let d = formatter.date(from: raw) {
                resetAt = d
                resetSeconds = max(0, d.timeIntervalSinceNow)
            }
        }
        if limit == nil && remaining == nil && resetSeconds == nil { return nil }
        let usedPercent: Double?
        if let limit, let remaining, limit > 0 {
            usedPercent = Double(max(0, limit - remaining)) / Double(limit) * 100.0
        } else {
            usedPercent = nil
        }
        return RateLimitSnapshot(limit: limit, remaining: remaining, resetSeconds: resetSeconds, resetAt: resetAt, usedPercent: usedPercent)
    }

    static func extractContextLimit(from message: String) -> Int {
        let keywords = ["maximum context length is ", "limit of ", "maximum of "]
        for keyword in keywords {
            if let range = message.range(of: keyword) {
                let after = message[range.upperBound...]
                var digits = ""
                for ch in after {
                    if ch.isNumber { digits.append(ch) } else { break }
                }
                if let limit = Int(digits) { return limit }
            }
        }
        return 128_000
    }

    static func extractJSONStringField(_ text: String, key: String) -> String {
        // Best-effort: find "key":"value" in a JSON error body.
        let pattern = "\"\(key)\"\\s*:\\s*\"([^\"]*)\""
        if let range = text.range(of: pattern, options: .regularExpression) {
            let inner = text[range]
            if let q = inner.range(of: "\":\"") {
                return String(inner[q.upperBound...].dropLast())
            }
        }
        return ""
    }
}
