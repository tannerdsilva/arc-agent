import Foundation
import Testing

import ArcAgentCore
@testable import ArcWebUI

extension ArcWebUITestRoot {
    /// what a failed turn leaves in the transcript, and what a chat records
    /// about the endpoint that served it. both are the difference between an
    /// actionable notice and "the connection to the model was lost".
    @Suite("Turn failure + endpoint metadata", .serialized)
    struct TurnFailureNoticeTests {

        private func endpoint(
            _ base: String = "http://127.0.0.1:8000/v1",
            model: String = "preset-model",
            provider: String = "custom"
        ) -> ProviderEndpoint {
            ProviderEndpoint(
                baseURL: URL(string: base)!,
                model: model,
                provider: provider,
                source: .preset,
                label: "p"
            )
        }

        @Test("a dead endpoint is reported by name, not as a lost connection")
        func unreachableNoticeNamesEndpoint() {
            let failure = LLMError.endpointUnreachable(
                endpoint: "http://[fdfd:a87e:5fad:9b12:702c:afe9:9af9:57b8]:8000/v1",
                detail: "connect timeout"
            )

            let text = TurnFailureNotice.text(stopped: false, failure: failure)

            #expect(text.contains("Cannot reach the model endpoint"))
            #expect(text.contains("[fdfd:a87e:5fad:9b12:702c:afe9:9af9:57b8]:8000/v1"))
            #expect(text.contains("connect timeout"))
            #expect(!text.contains("connection to the model was lost"))
        }

        @Test("any other transport failure keeps the generic interruption line")
        func genericTransportNotice() {
            let text = TurnFailureNotice.text(
                stopped: false, failure: LLMError.networkError("http://h:1/v1 — refused")
            )
            #expect(text == "Turn interrupted — the connection to the model was lost.")
        }

        @Test("a stream that ends without a terminal event is generic, not a crash")
        func nilFailureIsGeneric() {
            #expect(
                TurnFailureNotice.text(stopped: false, failure: nil)
                    == "Turn interrupted — the connection to the model was lost."
            )
        }

        @Test("a user stop is an outcome, never a failure — even with an error in hand")
        func stopWinsOverFailure() {
            let text = TurnFailureNotice.text(
                stopped: true,
                failure: LLMError.endpointUnreachable(endpoint: "http://h:1/v1", detail: "x")
            )
            #expect(text == "Turn interrupted — stopped by the user.")
        }

        @Test("a chat records the endpoint that served it, and marks itself webui")
        func stampRecordsTheEndpoint() async {
            var fixture = AppState.RenderFixture()
            fixture.sessions = [Session(id: "s1", title: "chat")]
            let app = AppState(renderFixture: fixture)

            await app.stampEndpoint(
                endpoint(model: "served-model", provider: "sam-slayer"), on: "s1"
            )

            let session = await app.sessions.first { $0.id == "s1" }
            #expect(session?.model == "served-model")
            #expect(session?.provider == "sam-slayer")
            #expect(session?.source == "webui")
        }

        @Test("a chat on a stable endpoint is stamped once, not every turn")
        func stampIsIdempotent() async {
            var fixture = AppState.RenderFixture()
            fixture.sessions = [
                Session(id: "s1", model: "m", provider: "p", source: "webui")
            ]
            let app = AppState(renderFixture: fixture)

            await app.stampEndpoint(endpoint(model: "m", provider: "p"), on: "s1")

            let session = await app.sessions.first { $0.id == "s1" }
            #expect(session?.model == "m")
            #expect(session?.provider == "p")
        }

        @Test("the settings row shows the address a chat will dial")
        func settingsRowShowsAuthority() {
            let ipv6 = ModelConfigPreset(
                name: "p", model: "m",
                baseURL: "http://[fdfd:a87e:5fad:9b12:702c:afe9:9af9:57b8]:8000/v1"
            )
            #expect(ipv6.endpointAuthority == "[fdfd:a87e:5fad:9b12:702c:afe9:9af9:57b8]:8000")

            let named = ModelConfigPreset(
                name: "p", model: "m", baseURL: "https://api.example.com/v1"
            )
            #expect(named.endpointAuthority == "api.example.com")

            // a typo stays visible in the row instead of collapsing to a placeholder
            let typo = ModelConfigPreset(
                name: "p", model: "m", baseURL: "http://fdfd::1:8000/v1"
            )
            #expect(typo.endpointAuthority == "http://fdfd::1:8000/v1")
        }
    }
}
