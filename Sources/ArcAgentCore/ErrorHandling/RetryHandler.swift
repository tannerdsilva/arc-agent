import Foundation

/// A retry handler with exponential backoff and jitter.
///
/// Used for transient failures like rate limits, network timeouts, and
/// temporary server errors. The backoff sequence follows:
///
/// 1st retry: 1s + jitter
/// 2nd retry: 2s + jitter
/// 3rd retry: 4s + jitter
/// 4th retry: 8s + jitter
/// Nth retry: min(cap, 2^(N-1)) + jitter
///
/// Jitter is ±50% of the base delay to avoid thundering herd problems.
public struct RetryHandler: Sendable {

    /// Maximum number of retry attempts.
    public let maxRetries: Int

    /// Initial backoff in seconds (doubles each attempt).
    public let baseDelay: TimeInterval

    /// Maximum backoff in seconds.
    public let maxDelay: TimeInterval

    /// Create a retry handler.
    public init(maxRetries: Int = 3, baseDelay: TimeInterval = 1.0, maxDelay: TimeInterval = 60.0) {
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    /// Compute the delay for a given retry attempt (0-indexed).
    ///
    /// - Parameter attempt: The retry attempt number (0 = first retry).
    /// - Returns: Delay in seconds with jitter applied.
    public func delay(for attempt: Int) -> TimeInterval {
        let exponential = baseDelay * pow(2.0, Double(attempt))
        let capped = min(exponential, maxDelay)

        // ±50% jitter
        let jitter = capped * 0.5 * Double.random(in: -1...1)
        return max(0.1, capped + jitter)
    }

    /// Whether the given attempt is within the retry budget.
    public func shouldRetry(_ attempt: Int) -> Bool {
        attempt < maxRetries
    }

    /// Sleep for the appropriate delay.
    public func wait(for attempt: Int) async throws {
        let d = delay(for: attempt)
        try await Task.sleep(nanoseconds: UInt64(d * 1_000_000_000))
    }
}

/// Classification of LLM errors for retry decisions.
public enum ErrorClass: Sendable {
    /// Transient — safe to retry (rate limit, timeout, 5xx).
    case retryable
    /// Permanent — do not retry (auth failure, model not found, bad request).
    case permanent
    /// Context overflow — needs compression before retry.
    case contextOverflow
}

/// Classify an LLM error for retry handling.
///
/// - Parameter error: The error to classify.
/// - Returns: The error class.
public func classifyError(_ error: Error) -> ErrorClass {
    switch error {
    case let llmError as LLMError:
        switch llmError {
        case .rateLimited:
            return .retryable
        case .timeout:
            return .retryable
        case .apiError(let statusCode, _):
            // 5xx are retryable, 4xx are not (except 429 which is rateLimited)
            if statusCode >= 500 {
                return .retryable
            }
            return .permanent
        case .authenticationFailed:
            return .permanent
        case .modelNotFound:
            return .permanent
        case .networkError:
            return .retryable
        case .decodingError:
            return .permanent
        }
    default:
        // Unknown errors — safe to retry once
        return .retryable
    }
}
