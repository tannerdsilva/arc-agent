import Foundation

/// The API mode determines how requests are formatted and sent to the provider.
public enum APIMode: String, Sendable, Codable, CaseIterable {
    /// OpenAI Chat Completions format (`/v1/chat/completions`).
    /// Used by ~95% of providers (OpenAI, OpenRouter, DeepSeek, xAI, etc.).
    case chatCompletions = "chat_completions"

    /// Anthropic Messages API format (`/v1/messages`).
    case messagesAPI = "messages_api"

    /// Google Gemini API format.
    case gemini
}

/// The authentication type for a provider.
public enum AuthType: String, Sendable, Codable, CaseIterable {
    /// Standard API key sent as a Bearer token in the Authorization header.
    case apiKey

    /// OAuth 2.0 device authorization flow.
    case oauthDeviceCode

    /// OAuth 2.0 with an external provider.
    case oauthExternal

    /// GitHub Copilot token exchange.
    case copilot

    /// AWS SDK credential chain.
    case awsSDK
}

/// A provider profile describing an LLM provider's API surface.
///
/// ``ProviderProfile`` is a value type that captures everything needed to
/// communicate with a specific LLM provider: the endpoint, authentication
/// method, supported features, and fallback options.
///
/// ## Design
///
/// This is a concrete value type, not a protocol — there is no polymorphic
/// behavior to abstract. Providers differ in *data* (base URL, headers,
/// supported features), not *behavior*. The ``LLMClient`` protocol handles
/// behavioral differences (request/response format).
public struct ProviderProfile: Sendable, Codable, Equatable {

    // MARK: - Identity

    /// The canonical name (e.g. `"openai"`, `"anthropic"`, `"openrouter"`).
    public let name: String

    /// Alternative names that resolve to this provider.
    public let aliases: [String]

    /// Human-readable display name (e.g. "OpenAI", "Anthropic").
    public let displayName: String

    /// Short description of the provider.
    public let description: String

    /// URL to sign up for an account.
    public let signupURL: String?

    // MARK: - API Surface

    /// The API mode determines the request/response format.
    public let apiMode: APIMode

    /// The authentication type.
    public let authType: AuthType

    /// The base URL for API requests.
    public let baseURL: URL

    /// Optional URL to fetch available models.
    public let modelsURL: URL?

    /// Default HTTP headers sent with every request.
    public let defaultHeaders: [String: String]

    // MARK: - Model Defaults

    /// Fixed temperature enforced by this provider. `nil` means use the
    /// client's default. A sentinel value means omit temperature entirely.
    public let fixedTemperature: Double?

    /// Default max tokens for this provider.
    public let defaultMaxTokens: Int?

    // MARK: - Capabilities

    /// Whether this provider supports vision/image inputs.
    public let supportsVision: Bool

    /// Whether this provider supports prompt caching keys.
    public let supportsPromptCacheKey: Bool

    // MARK: - Fallback

    /// Models to try if the primary model is unavailable or rate-limited.
    public let fallbackModels: [String]

    /// The hostname for network-level identification.
    public let hostname: String

    // MARK: - Init

    public init(
        name: String,
        aliases: [String] = [],
        displayName: String,
        description: String,
        signupURL: String? = nil,
        apiMode: APIMode = .chatCompletions,
        authType: AuthType = .apiKey,
        baseURL: URL,
        modelsURL: URL? = nil,
        defaultHeaders: [String: String] = [:],
        fixedTemperature: Double? = nil,
        defaultMaxTokens: Int? = nil,
        supportsVision: Bool = false,
        supportsPromptCacheKey: Bool = false,
        fallbackModels: [String] = [],
        hostname: String = ""
    ) {
        self.name = name
        self.aliases = aliases
        self.displayName = displayName
        self.description = description
        self.signupURL = signupURL
        self.apiMode = apiMode
        self.authType = authType
        self.baseURL = baseURL
        self.modelsURL = modelsURL
        self.defaultHeaders = defaultHeaders
        self.fixedTemperature = fixedTemperature
        self.defaultMaxTokens = defaultMaxTokens
        self.supportsVision = supportsVision
        self.supportsPromptCacheKey = supportsPromptCacheKey
        self.fallbackModels = fallbackModels
        self.hostname = hostname
    }
}
