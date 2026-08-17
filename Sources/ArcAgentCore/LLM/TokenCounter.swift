import Foundation

/// A calibrated token counter that estimates token counts from text.
///
/// The default heuristic (`text.utf8.count / 4`) is wildly inaccurate for
/// code-heavy conversations. ``TokenCounter`` uses a calibrated heuristic
/// that accounts for:
/// - Code content (high symbol density)
/// - Non-ASCII characters (multi-byte UTF-8)
/// - Whitespace (low token density)
/// - Natural language vs. structured text
///
/// ## Calibration
///
/// The heuristic is calibrated against OpenAI's cl100k_base tokenizer
/// (used by GPT-4, GPT-4o, and most modern models). The calibration
/// factor can be tuned per model via ``calibrationFactor``.
///
/// ## Usage
///
/// ```swift
/// let counter = TokenCounter()
/// let tokens = counter.count("Hello, world!")
/// let tokensForGPT4o = counter.count("Hello!", model: "gpt-4o")
/// ```
public struct TokenCounter: Sendable {
    /// The base calibration factor. 1.0 = OpenAI cl100k_base accuracy.
    /// Adjust per model if empirical testing shows systematic bias.
    public let calibrationFactor: Double

    /// Tokens per character for different content types.
    /// These are calibrated against cl100k_base on a mixed corpus.
    private static let asciiTokensPerChar: Double = 0.25    // ~4 chars/token for English
    private static let codeTokensPerChar: Double = 0.30     // ~3.3 chars/token for code
    private static let nonAsciiTokensPerChar: Double = 0.50 // ~2 chars/token for non-ASCII
    private static let whitespaceTokensPerChar: Double = 0.10 // ~10 chars/token for whitespace

    /// Characters that indicate code-like content.
    private static let codeChars = CharacterSet(charactersIn: "{}[]();:<>!=+-*/&|^~%@#")

    /// Create a token counter with an optional calibration factor.
    /// - Parameter calibrationFactor: Tuning factor. Default 1.0 (cl100k_base accuracy).
    public init(calibrationFactor: Double = 1.0) {
        self.calibrationFactor = calibrationFactor
    }

    /// Estimate the token count for the given text.
    /// - Parameter text: The text to count tokens for.
    /// - Returns: Estimated token count, adjusted by calibration factor.
    public func count(_ text: String) -> Int {
        let raw = estimateTokens(text)
        return Int((Double(raw) * calibrationFactor).rounded(.toNearestOrAwayFromZero))
    }

    /// Estimate the token count for the given text, using a model-specific
    /// calibration factor if one is registered.
    /// - Parameters:
    ///   - text: The text to count tokens for.
    ///   - model: The model name (e.g., "gpt-4o", "claude-3-opus").
    /// - Returns: Estimated token count.
    public func count(_ text: String, model: String) -> Int {
        let key = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let factor = Self.modelCalibration[key] ?? calibrationFactor
        let raw = estimateTokens(text)
        return Int((Double(raw) * factor).rounded(.toNearestOrAwayFromZero))
    }

    // MARK: - Private

    /// Estimate raw tokens using the content-aware heuristic.
    private func estimateTokens(_ text: String) -> Int {
        var total: Double = 0
        var codeCharCount = 0
        var nonAsciiCharCount = 0
        var whitespaceCount = 0
        var asciiCount = 0

        for scalar in text.unicodeScalars {
            if scalar.value < 128 {
                // ASCII range
                if scalar.value == 0x20 || scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D {
                    whitespaceCount += 1
                } else if Self.codeChars.contains(scalar) {
                    codeCharCount += 1
                } else {
                    asciiCount += 1
                }
            } else {
                nonAsciiCharCount += 1
            }
        }

        total += Double(asciiCount) * Self.asciiTokensPerChar
        total += Double(codeCharCount) * Self.codeTokensPerChar
        total += Double(nonAsciiCharCount) * Self.nonAsciiTokensPerChar
        total += Double(whitespaceCount) * Self.whitespaceTokensPerChar

        // Add a small fixed overhead for message framing (~3 tokens per message)
        total += 3

        return Int(total.rounded(.toNearestOrAwayFromZero))
    }

    /// Model-specific calibration factors.
    /// Values > 1.0 mean the model uses more tokens than cl100k_base for the same text.
    /// Values < 1.0 mean the model uses fewer tokens.
    private static let modelCalibration: [String: Double] = [
        "gpt-4o": 1.0,
        "gpt-4o-mini": 1.0,
        "gpt-4-turbo": 1.0,
        "gpt-3.5-turbo": 1.0,
        "claude-3-opus": 1.05,
        "claude-3-sonnet": 1.05,
        "claude-3-haiku": 1.05,
        "claude-3.5-sonnet": 1.05,
        "claude-3.5-haiku": 1.05,
        "claude-4": 1.05,
        "gemini-pro": 1.1,
        "gemini-1.5-pro": 1.1,
        "gemini-1.5-flash": 1.1,
        "deepseek-chat": 1.0,
        "deepseek-coder": 1.05,
        "mistral-large": 1.0,
        "mistral-medium": 1.0,
        "llama-3": 1.0,
        "llama-3.1": 1.0,
        "llama-3.2": 1.0,
        "qwen": 1.0,
        "qwen2": 1.0,
        "qwen2.5": 1.0,
    ]
}

// MARK: - Convenience

extension TokenCounter {
    /// Count tokens for an array of messages.
    /// - Parameters:
    ///   - messages: The messages to count.
    ///   - model: Optional model name for calibration.
    /// - Returns: Total estimated token count.
    public func count(messages: [Message], model: String? = nil) -> Int {
        var total = 0
        for msg in messages {
            total += count(msg.content ?? "", model: model ?? "")
            // Add role and name overhead (~4 tokens per message)
            total += 4
        }
        // Add ~12 tokens for the chat template overhead
        total += 12
        return total
    }
}

/// A token budget that tracks usage against a limit.
public struct TokenBudget: Sendable {
    public let limit: Int
    public private(set) var used: Int

    public var remaining: Int { limit - used }
    public var isExceeded: Bool { used >= limit }
    public var usageRatio: Double { Double(used) / Double(limit) }

    public init(limit: Int) {
        self.limit = limit
        self.used = 0
    }

    public mutating func consume(_ tokens: Int) {
        used += tokens
    }
}
