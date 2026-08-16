import Foundation

/// A registry of bundled provider profiles.
///
/// Providers are registered at compile time via static properties. The registry
/// supports lookup by name or alias, and can produce a list of all known
/// providers for display or configuration purposes.
///
/// ## Design
///
/// This is a concrete type with no protocol — the registry is a simple
/// dictionary lookup. If plugin-provided providers are needed later, a
/// ``ProviderRegistry`` protocol can be extracted.
public enum BundledProviders {

    // MARK: - OpenAI

    public static let openAI = ProviderProfile(
        name: "openai",
        aliases: ["openai-compatible"],
        displayName: "OpenAI",
        description: "OpenAI API — GPT-4o, GPT-4, o-series models",
        signupURL: "https://platform.openai.com/signup",
        baseURL: URL(string: "https://api.openai.com/v1")!,
        modelsURL: URL(string: "https://api.openai.com/v1/models"),
        defaultMaxTokens: 4096,
        supportsVision: true,
        supportsPromptCacheKey: true,
        hostname: "api.openai.com"
    )

    // MARK: - OpenRouter

    public static let openRouter = ProviderProfile(
        name: "openrouter",
        aliases: ["or"],
        displayName: "OpenRouter",
        description: "Unified API for 200+ models across providers",
        signupURL: "https://openrouter.ai/signup",
        baseURL: URL(string: "https://openrouter.ai/api/v1")!,
        defaultHeaders: [
            "HTTP-Referer": "https://github.com/tannerdsilva/arc-agent",
            "X-Title": "ARC Agent",
        ],
        defaultMaxTokens: 4096,
        supportsVision: true,
        hostname: "openrouter.ai"
    )

    // MARK: - Anthropic

    public static let anthropic = ProviderProfile(
        name: "anthropic",
        aliases: ["claude"],
        displayName: "Anthropic",
        description: "Anthropic API — Claude 3.5 Sonnet, Claude 3 Opus",
        signupURL: "https://console.anthropic.com/signup",
        apiMode: .messagesAPI,
        baseURL: URL(string: "https://api.anthropic.com/v1")!,
        defaultHeaders: [
            "anthropic-version": "2023-06-01",
        ],
        defaultMaxTokens: 4096,
        supportsVision: true,
        supportsPromptCacheKey: true,
        hostname: "api.anthropic.com"
    )

    // MARK: - DeepSeek

    public static let deepSeek = ProviderProfile(
        name: "deepseek",
        aliases: ["ds"],
        displayName: "DeepSeek",
        description: "DeepSeek API — DeepSeek-V3, DeepSeek-R1",
        signupURL: "https://platform.deepseek.com/signup",
        baseURL: URL(string: "https://api.deepseek.com/v1")!,
        defaultMaxTokens: 8192,
        hostname: "api.deepseek.com"
    )

    // MARK: - Google / Gemini

    public static let google = ProviderProfile(
        name: "google",
        aliases: ["gemini"],
        displayName: "Google AI",
        description: "Google Gemini API — Gemini 2.0 Flash, Gemini 2.0 Pro",
        signupURL: "https://aistudio.google.com/apikey",
        apiMode: .gemini,
        baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
        supportsVision: true,
        hostname: "generativelanguage.googleapis.com"
    )

    // MARK: - xAI

    public static let xAI = ProviderProfile(
        name: "xai",
        aliases: ["x", "grok"],
        displayName: "xAI",
        description: "xAI API — Grok-2, Grok-3",
        signupURL: "https://console.x.ai",
        baseURL: URL(string: "https://api.x.ai/v1")!,
        defaultMaxTokens: 4096,
        hostname: "api.x.ai"
    )

    // MARK: - MiniMax

    public static let miniMax = ProviderProfile(
        name: "minimax",
        aliases: ["mm"],
        displayName: "MiniMax",
        description: "MiniMax API — MiniMax-Text-01",
        signupURL: "https://platform.minimaxi.com",
        baseURL: URL(string: "https://api.minimaxi.com/v1")!,
        defaultMaxTokens: 4096,
        hostname: "api.minimaxi.com"
    )

    // MARK: - Together AI

    public static let together = ProviderProfile(
        name: "together",
        aliases: ["together-ai"],
        displayName: "Together AI",
        description: "Together AI — hosted open-source models",
        signupURL: "https://api.together.ai/signup",
        baseURL: URL(string: "https://api.together.xyz/v1")!,
        defaultMaxTokens: 4096,
        hostname: "api.together.xyz"
    )

    // MARK: - Groq

    public static let groq = ProviderProfile(
        name: "groq",
        aliases: ["groq-cloud"],
        displayName: "Groq",
        description: "Groq Cloud — ultra-low-latency inference",
        signupURL: "https://console.groq.com",
        baseURL: URL(string: "https://api.groq.com/openai/v1")!,
        defaultMaxTokens: 8192,
        hostname: "api.groq.com"
    )

    // MARK: - Perplexity

    public static let perplexity = ProviderProfile(
        name: "perplexity",
        aliases: ["pplx"],
        displayName: "Perplexity",
        description: "Perplexity API — Sonar, online LLMs",
        signupURL: "https://www.perplexity.ai/settings/api",
        baseURL: URL(string: "https://api.perplexity.ai")!,
        defaultMaxTokens: 4096,
        hostname: "api.perplexity.ai"
    )

    // MARK: - All Providers

    /// All bundled providers, keyed by name.
    public static let all: [String: ProviderProfile] = {
        let providers: [ProviderProfile] = [
            openAI, openRouter, anthropic, deepSeek, google, xAI,
            miniMax, together, groq, perplexity,
        ]
        var dict: [String: ProviderProfile] = [:]
        for provider in providers {
            dict[provider.name] = provider
            for alias in provider.aliases {
                dict[alias] = provider
            }
        }
        return dict
    }()

    /// Look up a provider by name or alias.
    public static func resolve(_ name: String) -> ProviderProfile? {
        all[name.lowercased()]
    }

    /// All unique provider profiles (deduplicated by name).
    public static var unique: [ProviderProfile] {
        var seen = Set<String>()
        return all.values.filter { profile in
            guard !seen.contains(profile.name) else { return false }
            seen.insert(profile.name)
            return true
        }
        .sorted { $0.name < $1.name }
    }
}
