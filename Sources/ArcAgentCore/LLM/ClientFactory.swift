import Foundation
import AsyncHTTPClient

/// Builds the right `LLMClient` for a provider profile + model — the
/// per-provider quirk router (Hermes `agent_init` provider selection + the
/// per-provider adapter files). `APIMode` on the profile selects the wire
/// dialect; `ModelMetadata` supplies thinking fields, cache styles, tool
/// schema dialects, and output caps.
public enum ClientFactory {

    /// Cached metadata for a model+provider (registry is table-driven; cache
    /// makes repeated lookups cheap — registry is immutable anyway).
    public static func metadata(
        model: String,
        provider: String? = nil,
        configuredContextLength: Int? = nil
    ) -> ModelMetadata {
        ModelMetadataRegistry.shared.metadata(
            for: model,
            provider: provider,
            configuredContextLength: configuredContextLength
        )
    }

    /// Adapt tool schemas to the selected dialect.
    public static func adaptTools(
        _ tools: [[String: Any]]?,
        metadata: ModelMetadata
    ) -> [[String: Any]]? {
        guard let tools, !tools.isEmpty else { return tools }
        switch metadata.toolSchemaStyle {
        case .moonshot:
            return MoonshotSchema.sanitizeTools(tools)
        case .openAI, .anthropic, .gemini, .bedrock:
            return tools
        }
    }

    /// Create a client for the given profile/model. Returns a client that
    /// speaks the profile's API mode. `reasoningEffort` is translated per
    /// provider (Hermes vocabulary preserved verbatim).
    public static func makeClient(
        profile: ProviderProfile,
        model: String,
        apiKey: String,
        httpClient: HTTPClient,
        reasoningEffort: String? = nil,
        configuredContextLength: Int? = nil,
        maxTokens: Int? = nil,
        temperature: Double? = nil
    ) -> any LLMClient {
        let meta = metadata(model: model, provider: profile.name, configuredContextLength: configuredContextLength)
        let toolCap = meta.maxOutputTokens ?? maxTokens ?? 8192

        switch profile.apiMode {
        case .messagesAPI:
            return AnthropicMessagesClient(
                baseURL: profile.baseURL,
                apiKey: apiKey,
                model: model,
                metadata: meta,
                maxTokens: toolCap,
                temperature: temperature,
                httpClient: httpClient
            ).with(thinkingEffort: reasoningEffort)
        case .gemini:
            return GeminiClient(
                baseURL: profile.baseURL,
                apiKey: apiKey,
                model: model,
                metadata: meta,
                maxOutputTokens: maxTokens,
                temperature: temperature,
                thinkingEffort: reasoningEffort,
                httpClient: httpClient
            )
        case .responses:
            return CodexResponsesClient(
                baseURL: profile.baseURL,
                apiKey: apiKey,
                model: model,
                metadata: meta,
                maxOutputTokens: maxTokens,
                temperature: temperature,
                reasoningEffort: reasoningEffort,
                httpClient: httpClient
            )
        case .chatCompletions:
            // OpenAI dialect. Tool-schema adaptation for moonshot-family
            // models is applied by the caller via `adaptTools` (the client
            // itself passes schemas through verbatim).
            return OpenAICompatibleClient(
                baseURL: profile.baseURL,
                apiKey: apiKey,
                model: model,
                httpClient: httpClient,
                defaultParameters: RequestParameters(
                    temperature: temperature,
                    maxTokens: maxTokens
                ),
                additionalHeaders: profile.defaultHeaders
            )
        }
    }

    /// Vertex AI: the OpenAI-compatible endpoint on `aiplatform.googleapis.com`
    /// with a live service-account bearer token (Hermes `vertex_adapter.py`).
    public static func makeVertexClient(
        profile: ProviderProfile,
        model: String,
        serviceAccount: VertexAuth.ServiceAccount,
        httpClient: HTTPClient,
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        configuredContextLength: Int? = nil
    ) async throws -> OpenAICompatibleClient {
        let auth = VertexAuth(account: serviceAccount)
        let token = try await auth.accessToken()
        let meta = metadata(model: model, provider: "google", configuredContextLength: configuredContextLength)
        var headers = profile.defaultHeaders
        headers["Authorization"] = "Bearer \(token)"
        return OpenAICompatibleClient(
            baseURL: profile.baseURL,
            apiKey: token,
            model: model,
            httpClient: httpClient,
            defaultParameters: RequestParameters(
                temperature: temperature,
                maxTokens: maxTokens ?? meta.maxOutputTokens
            ),
            additionalHeaders: headers
        )
    }

    /// Bedrock is a distinct profile family (AWS credentials from env); the
    /// factory throws a descriptive error when credentials are absent so the
    /// caller can fail fast with guidance instead of a SigV4 mystery.
    public static func makeBedrockClient(
        profile: ProviderProfile,
        model: String,
        httpClient: HTTPClient,
        reasoningEffort: String? = nil,
        configuredContextLength: Int? = nil
    ) throws -> BedrockConverseClient {
        guard let signer = AWSV4Signer.fromEnvironment() else {
            throw LLMError.authenticationFailed
        }
        let region = ProcessInfo.processInfo.environment["AWS_REGION"]
            ?? ProcessInfo.processInfo.environment["AWS_DEFAULT_REGION"]
            ?? "us-east-1"
        let meta = metadata(model: model, provider: "anthropic", configuredContextLength: configuredContextLength)
        _ = reasoningEffort // Bedrock effort handled via model metadata by the client
        return BedrockConverseClient(
            region: region,
            signer: signer,
            model: model,
            metadata: meta,
            httpClient: httpClient
        )
    }
}
