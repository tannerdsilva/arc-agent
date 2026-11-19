import Foundation
import Testing

@testable import ArcAgentCore

extension ArcCoreTestRoot {
    /// the one precedence rule every surface resolves through. the matrix is
    /// pure, so it pins the decision without a config file or a network.
    @Suite("Provider endpoint resolution", .serialized)
    struct ProviderEndpointTests {

        private func config(
            model: String = "config-model",
            provider: String = "vllm",
            baseURL: String? = "http://127.0.0.1:8000/v1"
        ) -> ModelConfig {
            ModelConfig(defaultModel: model, provider: provider, baseURL: baseURL)
        }

        @Test("an explicit choice wins over the config on every field")
        func choiceWins() throws {
            let endpoint = try ProviderEndpointResolver.resolve(
                choice: .init(
                    baseURL: "http://10.0.0.5:9000/v1",
                    model: "preset-model",
                    provider: "custom",
                    source: .preset,
                    label: "my-preset"
                ),
                config: config()
            )

            #expect(endpoint.baseURL.absoluteString == "http://10.0.0.5:9000/v1")
            #expect(endpoint.model == "preset-model")
            #expect(endpoint.provider == "custom")
            #expect(endpoint.source == .preset)
            #expect(endpoint.label == "my-preset")
        }

        @Test("blank choice fields defer to the config, not to an empty string")
        func blankFieldsDefer() throws {
            let endpoint = try ProviderEndpointResolver.resolve(
                choice: .init(baseURL: "", model: "  ", provider: ""),
                config: config()
            )

            #expect(endpoint.baseURL.absoluteString == "http://127.0.0.1:8000/v1")
            #expect(endpoint.model == "config-model")
            #expect(endpoint.provider == "vllm")
            #expect(endpoint.source == .config)
        }

        @Test("no config base URL falls to the built-in default, and says so")
        func configFallback() throws {
            let endpoint = try ProviderEndpointResolver.resolve(
                choice: nil,
                config: config(baseURL: nil)
            )

            #expect(endpoint.baseURL == ProviderEndpointResolver.fallbackBaseURL)
            #expect(endpoint.source == .fallback)
            #expect(endpoint.model == "config-model")
        }

        @Test("an IPv6 literal keeps its brackets and resolves a port")
        func ipv6Literal() throws {
            let literal = "http://[fdfd:a87e:5fad:9b12:702c:afe9:9af9:57b8]:8000/v1"
            let endpoint = try ProviderEndpointResolver.resolve(
                choice: .init(baseURL: literal),
                config: config()
            )

            #expect(endpoint.baseURL.absoluteString == literal)
            #expect(endpoint.baseURL.host == "fdfd:a87e:5fad:9b12:702c:afe9:9af9:57b8")
            #expect(endpoint.baseURL.port == 8000)
            // the legible authority keeps the brackets — a bare `fdfd:…:8000`
            // reads like a truncated list of addresses.
            #expect(endpoint.authority == "[fdfd:a87e:5fad:9b12:702c:afe9:9af9:57b8]:8000")
        }

        @Test("an unbracketed IPv6 literal is rejected with the bracket hint")
        func unbracketedIPv6IsNamed() {
            let bare = "http://fdfd:a87e:5fad:9b12:702c:afe9:9af9:57b8:8000/v1"
            #expect(throws: ProviderEndpointError.self) {
                try ProviderEndpointResolver.resolve(
                    choice: .init(baseURL: bare), config: config()
                )
            }
            // the message must do the work: name the string AND the repair.
            let issue = ProviderEndpointResolver.authorityIssue(bare)
            #expect(issue?.contains("square brackets") == true)
            #expect(issue?.contains("[fdfd:a87e") == true)
        }

        @Test("an unparseable choice names its source instead of silently falling back")
        func unparseableNamesSource() {
            do {
                _ = try ProviderEndpointResolver.resolve(
                    choice: .init(baseURL: "not a url", source: .preset, label: "typo"),
                    config: config()
                )
                Issue.record("expected the resolution to throw")
            } catch let error as ProviderEndpointError {
                #expect(error.description.contains("not a url"))
                #expect(error.description.contains("preset"))
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }

        @Test("a non-numeric port is rejected")
        func badPort() {
            #expect(ProviderEndpointResolver.authorityIssue("http://host:abc/v1") != nil)
            #expect(ProviderEndpointResolver.authorityIssue("http://host:/v1") != nil)
            #expect(ProviderEndpointResolver.authorityIssue("http://host:8000/v1") == nil)
        }

        @Test("only http(s) absolute URLs are accepted")
        func schemeGate() {
            #expect(throws: ProviderEndpointError.self) {
                try ProviderEndpointResolver.parse("ftp://host/v1", source: .config)
            }
            #expect(throws: ProviderEndpointError.self) {
                try ProviderEndpointResolver.parse("/v1", source: .config)
            }
            #expect((try? ProviderEndpointResolver.parse("https://host/v1", source: .config)) != nil)
        }

        @Test("the description names the model, the URL and the origin")
        func descriptionIsHonest() throws {
            let endpoint = try ProviderEndpointResolver.resolve(
                choice: .init(baseURL: "http://h:1/v1", model: "m", source: .preset, label: "p"),
                config: config()
            )
            #expect(endpoint.description == "m @ http://h:1/v1 (preset: p)")
        }
    }
}
