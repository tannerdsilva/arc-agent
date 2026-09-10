import Foundation

// MARK: - Failure taxonomy (Hermes `error_classifier.py` FailoverReason)

/// The Hermes failure-taxonomy. Each class maps to a recovery strategy:
/// retry/backoff, credential rotation, fallback model, compression, or abort.
public enum FailoverReason: String, Sendable, Equatable, CaseIterable {
    case auth                  // expired/invalid key → rotate credentials
    case authPermanent         // revoked key/bad org → no rotation helps
    case billing               // no credits/quota → surface to user
    case rateLimit             // 429 → honor retry-after, backoff
    case upstreamRateLimit     // provider says we're above ITS quota → longer backoff
    case overloaded            // 529/503 provider overload → exponential backoff
    case serverError           // 5xx → retry with backoff
    case timeout               // request deadline → retry; transport recovery
    case staleStream           // stream went quiet → reconnect, patience budget
    case tls                   // TLS handshake/fingerprint → transport recovery
    case contextLength         // too many tokens → compress + retry
    case contentPolicy         // refusal/filter → non-retryable, tell user
    case decoding              // invalid response shape → retry once, then abort
    case emptyResponse         // provider returned nothing useful → nudge/storm guard
    case unknown

    /// Whether retrying this failure can succeed.
    public var isRetryable: Bool {
        switch self {
        case .auth, .billing, .authPermanent, .contentPolicy, .unknown:
            return false
        case .rateLimit, .upstreamRateLimit, .overloaded, .serverError,
             .timeout, .staleStream, .tls, .contextLength, .decoding, .emptyResponse:
            return true
        }
    }

    /// Whether falling back to another model can help.
    public var isFallbackCandidate: Bool {
        switch self {
        case .overloaded, .serverError, .upstreamRateLimit, .staleStream, .auth:
            return true
        default:
            return false
        }
    }
}

/// Hermes `TLSReason` family: which transport-level drift occurred.
public enum TLSReason: String, Sendable, Equatable {
    case certificateExpired
    case certificateUntrusted
    case certificateMismatch
    case handshakeFailure
    case other
}

/// A classified API failure: the reason, plus recovery advice the loop acts on.
public struct ClassifiedFailure: Sendable, Equatable {
    public let reason: FailoverReason
    public let statusCode: Int?
    public let retryAfter: Int?
    public let tlsReason: TLSReason?
    /// Provider string returned in the error body (kept for the report line).
    public let detail: String?

    public init(reason: FailoverReason, statusCode: Int? = nil,
                retryAfter: Int? = nil, tlsReason: TLSReason? = nil, detail: String? = nil) {
        self.reason = reason
        self.statusCode = statusCode
        self.retryAfter = retryAfter
        self.tlsReason = tlsReason
        self.detail = detail
    }
}

/// Classify an `LLMError` (or any Error) into the FailoverReason taxonomy.
/// Mirrors Hermes' `classify_api_error`: status-first, then body-pattern
/// detection, then transport exceptions.
public enum ErrorClassifier {

    public static func classify(_ error: Error) -> ClassifiedFailure {
        if let llm = error as? LLMError { return classifyLLM(llm) }
        let description = String(describing: error).lowercased()
        // NIO / Foundation transport exceptions (Hermes TLS + connect classes).
        if description.contains("tls") || description.contains("certificate")
            || description.contains("ssl") || description.contains("handshake") {
            return ClassifiedFailure(reason: .tls, tlsReason: tlsReason(from: description))
        }
        if description.contains("connection") || description.contains("connect")
            || description.contains("reset") || description.contains("broken pipe") {
            return ClassifiedFailure(reason: .timeout)
        }
        return ClassifiedFailure(reason: .unknown, detail: String(describing: error))
    }

    static func classifyLLM(_ error: LLMError) -> ClassifiedFailure {
        switch error {
        case .authenticationFailed:
            return ClassifiedFailure(reason: .auth)
        case .rateLimited(let retryAfter):
            return ClassifiedFailure(reason: .rateLimit, retryAfter: retryAfter)
        case .timeout:
            return ClassifiedFailure(reason: .timeout)
        case .contextLengthExceeded:
            return ClassifiedFailure(reason: .contextLength)
        case .contentPolicyViolation:
            return ClassifiedFailure(reason: .contentPolicy)
        case .decodingError:
            return ClassifiedFailure(reason: .decoding)
        case .networkError:
            return ClassifiedFailure(reason: .timeout)
        case .modelNotFound:
            return ClassifiedFailure(reason: .unknown)
        case .apiError(let status, let message):
            return classifyAPI(status: status, message: message)
        }
    }

    /// Status + body-pattern classification (Hermes
    /// `classify_api_error` body-pattern detection).
    static func classifyAPI(status: Int, message: String) -> ClassifiedFailure {
        let lower = message.lowercased()
        switch status {
        case 401, 403:
            if lower.contains("invalid") || lower.contains("expired") {
                return ClassifiedFailure(reason: .authPermanent, statusCode: status)
            }
            return ClassifiedFailure(reason: .auth, statusCode: status)
        case 402, 4030:
            return ClassifiedFailure(reason: .billing, statusCode: status)
        case 408:
            return ClassifiedFailure(reason: .timeout, statusCode: status)
        case 429:
            return ClassifiedFailure(reason: .rateLimit, statusCode: status)
        case 529:
            return ClassifiedFailure(reason: .overloaded, statusCode: status)
        case 500, 502, 503, 504:
            return ClassifiedFailure(reason: .serverError, statusCode: status)
        case 400:
            if lower.contains("context") || lower.contains("token limit") {
                return ClassifiedFailure(reason: .contextLength, statusCode: status)
            }
            if lower.contains("content") || lower.contains("safety") || lower.contains("blocked") {
                return ClassifiedFailure(reason: .contentPolicy, statusCode: status)
            }
            return ClassifiedFailure(reason: .unknown, statusCode: status, detail: message)
        default:
            if lower.contains("quota") || lower.contains("billing") {
                return ClassifiedFailure(reason: .billing, statusCode: status)
            }
            if lower.contains("overloaded") || lower.contains("capacity") {
                return ClassifiedFailure(reason: .overloaded, statusCode: status)
            }
            return ClassifiedFailure(reason: .unknown, statusCode: status, detail: message)
        }
    }

    static func tlsReason(from description: String) -> TLSReason? {
        if description.contains("expired") { return .certificateExpired }
        if description.contains("untrusted") || description.contains("not trusted") {
            return .certificateUntrusted
        }
        if description.contains("mismatch") { return .certificateMismatch }
        if description.contains("handshake") { return .handshakeFailure }
        return .other
    }
}

/// Backoff for a classified failure (Hermes retry policy: rate limits honor
/// retry-after; overload/server errors use exponential with provider-specific
/// ladders; the rest use the standard ladder with jitter).
public enum FailureBackoff {
    public static func delay(for reason: FailoverReason, attempt: Int, retryAfter: Int? = nil) -> Double {
        switch reason {
        case .rateLimit, .upstreamRateLimit:
            return Double(retryAfter ?? Int(Self.boundedExp(attempt, base: 5, cap: 60)))
        case .overloaded:
            // Hermes ZAI coding overload ladder: 30, 60, 90, 120
            let ladder = [30.0, 60.0, 90.0, 120.0]
            return ladder[min(attempt, ladder.count - 1)]
        case .serverError:
            return Self.boundedExp(attempt, base: 2, cap: 30)
        case .staleStream, .timeout, .tls, .decoding:
            return Self.boundedExp(attempt, base: 1, cap: 15)
        default:
            return Self.boundedExp(attempt, base: 1, cap: 30)
        }
    }

    static func boundedExp(_ attempt: Int, base: Double, cap: Double) -> Double {
        let exp = base * pow(2.0, Double(max(0, attempt)))
        return min(exp, cap) * Double.random(in: 0.8...1.2) // jitter
    }
}
