import Testing

import WebUI
@testable import ArcWebUI

extension ArcWebUITestRoot {
    /// the storage family is the pilot for the declared-surface port: one
    /// `Action` type stands where two string-registered handlers and two
    /// emission sites stood, and the row payload rides the wire identity
    /// instead of a DOM id the handler re-derived with `targetId` + `dropFirst`.
    @Suite("storage action", .serialized)
    struct StorageActionTests {

        /// records what a registration hands its handler, so "the handler never
        /// ran" is observed rather than inferred from an empty return.
        private actor Recorder {
            private(set) var actions: [StorageAction] = []
            func record(_ action: StorageAction) { actions.append(action) }
        }

        /// slot 0 is the verb, slot 1 the payload, and every slot is base64url;
        /// the wire id is the one attribute both sides read, so the round trip
        /// is the contract.
        @Test("edit round-trips through the wire identity")
        func editRoundTrips() throws {
            let key = StorageAction.edit("conn-1").key
            #expect(key.wireID == "storage~edit~conn-1", "wire id drifted: \(key.wireID)")

            let parsed = try #require(ActionKey(wireID: key.wireID))
            #expect(parsed == key)

            let decoded = try #require(StorageAction(
                key: parsed,
                event: EventData(component: ComponentID(key.wireID), event: .click)))
            #expect(decoded == .edit("conn-1"))
        }

        @Test("delete keeps its verb in slot 0 and its id in slot 1")
        func deleteSpellsItsVerb() throws {
            let key = StorageAction.delete("conn-1").key
            #expect(key.wireID == "storage~delete~conn-1", "wire id drifted: \(key.wireID)")

            let parsed = try #require(ActionKey(wireID: key.wireID))
            let decoded = try #require(StorageAction(
                key: parsed,
                event: EventData(component: ComponentID(key.wireID), event: .click)))
            #expect(decoded == .delete("conn-1"))
        }

        /// end to end: the family registration decodes the frame the view emits
        /// and the handler receives the typed case, not a string to re-split.
        @Test("dispatch decodes the frame before the handler runs")
        func dispatchRunsTheTypedHandler() async {
            let router = EventRouter()
            let recorder = Recorder()
            router.on(StorageAction.self) { action, _ in
                await recorder.record(action)
                return []
            }

            let outcome = await router.dispatch(
                EventData(component: ComponentID("storage~edit~conn-1"), event: .click))

            let seen = await recorder.actions
            #expect(seen == [.edit("conn-1")], "the handler saw \(seen)")
            #expect(outcome.fragments.isEmpty)
        }

        /// a payload the framework could not have minted is dropped at the
        /// decode door: the handler is not called and the frame answers nothing.
        @Test("a malformed payload is dropped before the handler")
        func malformedPayloadIsDropped() async {
            let router = EventRouter()
            let recorder = Recorder()
            router.on(StorageAction.self) { action, _ in
                await recorder.record(action)
                return []
            }

            // `!!!` is outside the base64url alphabet, so the id slot does not
            // decode. the verb is a slot too — spelling `edit` literally puts
            // base64 in slot 0, not the verb — so both frames die at the door.
            for frame in ["storage~edit~!!!", "storage~edit~", "storage~wrongverb~conn-1"] {
                let outcome = await router.dispatch(
                    EventData(component: ComponentID(frame), event: .click))
                #expect(outcome.fragments.isEmpty, "\(frame) must answer nothing")
            }

            let seen = await recorder.actions
            #expect(seen.isEmpty, "an undecodable payload must not reach the handler: \(seen)")
        }

        /// the emission half: one attribute carries the whole identity, and a
        /// render registers nothing — only the family registration routes.
        @Test("View.action emits the wire identity and registers nothing")
        func actionEmitsWithoutRegistering() {
            let router = EventRouter()
            let html = RenderContext.$current.withValue(RenderContext(router: router)) {
                Div { Text("row") }
                    .action(StorageAction.edit("conn-1"))
                    .markup.html
            }

            #expect(html.contains("data-component-id=\"storage~edit~conn-1\""), "emitted: \(html)")
            #expect(html.contains("data-event=\"click\""), "emitted: \(html)")
            #expect(!html.contains("storage-edit-"), "the old DOM id must not be emitted: \(html)")
            #expect(router.handlerCount(in: .default) == 0, "rendering registered a handler")
        }
    }
}
