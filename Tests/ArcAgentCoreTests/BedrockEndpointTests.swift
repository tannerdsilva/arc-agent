import Testing
@testable import ArcAgentCore
import Foundation
import AsyncHTTPClient

// =========================================================================
// MARK: - Bedrock endpoint construction (C3 regression)
//
// The endpoint URL is built with URLComponents and fails with a thrown
// error instead of force-unwrapping `URL(string:)!` (a process crash on a
// malformed config value).
// =========================================================================

@Suite("Bedrock endpoint")
struct BedrockEndpointTests {

    private func makeClient(
        model: String = "anthropic.claude-3-sonnet-20240229-v1:0",
        region: String = "us-east-1",
        httpClient: HTTPClient
    ) -> BedrockConverseClient {
        BedrockConverseClient(
            region: region,
            signer: AWSV4Signer(accessKey: "AKIDEXAMPLE", secretKey: "secret", region: region),
            model: model,
            httpClient: httpClient
        )
    }

    @Test("endpoint builds a standard converse URL without crashing")
    func endpointBuilds() throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        defer { try? httpClient.shutdown() }
        let client = makeClient(httpClient: httpClient)
        let url = try client.endpoint(stream: false)
        #expect(url.scheme == "https")
        #expect(url.host == "bedrock-runtime.us-east-1.amazonaws.com")
        #expect(url.path.hasPrefix("/model/"))
        #expect(url.path.hasSuffix("/converse"))
        let streamURL = try client.endpoint(stream: true)
        #expect(streamURL.path.hasSuffix("/converse-stream"))
    }

    @Test("model ids with reserved characters stay percent-encoded")
    func endpointEncodesModel() throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        defer { try? httpClient.shutdown() }
        let client = makeClient(model: "my vendor/model with space", httpClient: httpClient)
        let url = try client.endpoint(stream: false)
        #expect(url.path.contains("%20"), "spaces must be percent-encoded: \(url.path)")
    }
}
