import ArcAgentCore
import Foundation
import Testing
import WebUICore
@testable import ArcWebUI

// ===========================================================================
// MARK: - model configurations are editable in place
//
// A model configuration is the web UI's provider endpoint record: name, model,
// provider, base URL, key, context length, output budget. Before this suite the
// only actions on a row were add and remove — fixing a typo'd base URL or
// rotating a key meant deleting the record, which dropped every chat pin and
// auxiliary route that named it, then recreating it by hand.
//
// The tests below pin the edit path: an affordance on every row, a pre-filled
// form, an in-place mutation that preserves the row's position and the pins
// that name it, secret handling (blank keeps the stored key, never rendered),
// and the managed `config.json` preset writing through instead of being
// reverted at the next boot.
// ===========================================================================

extension ArcWebUITestRoot {

    @Suite("model config editing", .serialized)
    struct ModelConfigEditTests {

        /// Two user-owned configurations plus an active pick, a chat pin, and the
        /// legacy auxiliary map, so a rename has every pin class to repoint.
        private static func state(apiKey: String = "") -> AppState {
            var f = AppState.RenderFixture()
            f.settings.modelConfigs = [
                ModelConfigPreset(name: "primary", model: "gpt-4o", provider: "openai",
                                  baseURL: "https://api.openai.com/v1", apiKey: apiKey,
                                  contextLength: 128_000, maxOutputTokens: 32_768, source: "ui"),
                ModelConfigPreset(name: "local", model: "llama-3", provider: "ollama",
                                  baseURL: "http://localhost:11434/v1", source: "ui"),
            ]
            f.settings.activeConfig = "primary"
            f.settings.sessionConfig = ["sess-a": "primary", "sess-b": "local"]
            f.settings.auxiliaryModels = ["approval": "primary"]
            return AppState(renderFixture: f)
        }

        /// The config-owned preset as the reconciler leaves it: name == model,
        /// provenance `config.json`, and the matching `ArcConfig` model block.
        private static func managedState() -> AppState {
            var f = AppState.RenderFixture()
            f.settings.modelConfigs = [
                ModelConfigPreset(name: "nemotron", model: "nemotron", provider: "vllm",
                                  baseURL: "http://old:8000/v1", contextLength: 1_000,
                                  source: ConfigModelReconciler.managedSource),
            ]
            f.settings.activeConfig = "nemotron"
            f.settings.sessionConfig = ["s1": "nemotron"]
            f.arcConfig.model = ModelConfig(defaultModel: "nemotron", provider: "vllm",
                                            baseURL: "http://old:8000/v1", contextLength: 1_000)
            return AppState(renderFixture: f)
        }

        private static func draft(
            name: String = "primary",
            model: String = "gpt-4o",
            provider: String = "openai",
            baseURL: String = "https://api.openai.com/v1",
            apiKey: String = "",
            clearAPIKey: Bool = false,
            contextLength: Int? = 128_000,
            maxOutputTokens: Int? = 32_768
        ) -> ModelConfigDraft {
            ModelConfigDraft(name: name, model: model, provider: provider, baseURL: baseURL,
                             apiKey: apiKey, clearAPIKey: clearAPIKey,
                             contextLength: contextLength, maxOutputTokens: maxOutputTokens)
        }

        // MARK: - affordance

        @Test("every configuration row exposes an edit control")
        func rowsExposeEdit() async {
            let html = await Self.state().settingsMain().markup.html
            let primary = "mc-edit-" + enc("primary")
            let local = "mc-edit-" + enc("local")
            #expect(html.contains("id=\"\(primary)\""),
                    "the primary row has no edit control — a mistake in it can only be removed")
            #expect(html.contains("id=\"\(local)\""),
                    "the local row has no edit control")
            // the same click-identity contract the remove path holds: the rows
            // ride `targetId` from the list boundary, which must carry no id.
            #expect(html.contains("data-component-id=\"modelcfg-list\""))
            let withoutComponentAttrs = html.replacingOccurrences(
                of: "data-component-id=\"", with: "data-component-id-")
            #expect(!withoutComponentAttrs.contains("id=\"modelcfg-list\""),
                    "the list boundary must not carry its own id")
        }

        @Test("the edit form keeps the submit payload field names")
        func formFieldContract() async {
            let app = Self.state()
            await app.openModelConfigEdit("primary")
            let html = await app.settingsMain().markup.html
            for field in ["mce-name", "mce-model", "mce-provider", "mce-baseurl",
                          "mce-apikey", "mce-ctx", "mce-maxtok"] {
                #expect(html.contains("name=\"\(field)\""),
                        "\(field) is a submit payload key the engine builds from `name`")
            }
            #expect(html.contains("id=\"modelcfg-edit-form\""))
            #expect(html.contains("data-component-id=\"modelcfg-edit-form\""))
            #expect(!html.contains("id=\"modelcfg-add-form\""),
                    "both the add form and the edit form rendered at once")
        }

        @Test("the editor's field identities are disjoint from the add form's")
        func editorFieldsDoNotCollideWithTheAddForm() async {
            // the engine restores input state across a patch by field id, so two
            // forms sharing ids let the add form's (empty) values overwrite the
            // editor's pre-filled ones. measured live: the editor opened blank.
            let app = Self.state()

            func configFieldNames(_ html: String) -> Set<String> {
                let names = html.components(separatedBy: "name=\"")
                    .dropFirst()
                    .compactMap { $0.split(separator: "\"").first.map(String.init) }
                return Set(names.filter { $0.hasPrefix("mc-") || $0.hasPrefix("mce-") })
            }

            let idle = await app.settingsMain().markup.html
            await app.openModelConfigEdit("primary")
            let editing = await app.settingsMain().markup.html

            #expect(configFieldNames(idle).contains("mc-name"), "the add form's keys moved")
            #expect(configFieldNames(editing).contains("mce-name"), "the editor's keys moved")
            let collision = configFieldNames(idle).intersection(configFieldNames(editing))
            #expect(collision.isEmpty,
                    "shared field ids let a patch restore copy one form's values over the other's: \(collision.sorted())")
        }

        // MARK: - pre-fill and secret handling

        @Test("opening the editor pre-fills the form and never renders the stored key")
        func editorPrefillsWithoutLeakingTheKey() async {
            let app = Self.state(apiKey: "sk-live-secret")
            await app.openModelConfigEdit("primary")
            let html = await app.settingsMain().markup.html

            #expect(html.contains("value=\"primary\""), "name was not pre-filled")
            #expect(html.contains("value=\"gpt-4o\""), "model was not pre-filled")
            #expect(html.contains("value=\"openai\""), "provider was not pre-filled")
            #expect(html.contains("value=\"https://api.openai.com/v1\""), "base URL was not pre-filled")
            #expect(html.contains("value=\"128000\""), "context length was not pre-filled")
            #expect(html.contains("value=\"32768\""), "output budget was not pre-filled")
            #expect(!html.contains("sk-live-secret"),
                    "the stored key was rendered into the page — a patch frame would ship it to the browser")
            #expect(html.contains("stored — leave blank to keep it"),
                    "the key field does not say the stored key is kept")
        }

        @Test("a blank key field keeps the stored secret")
        func blankKeyKeepsTheSecret() async {
            let app = Self.state(apiKey: "sk-old")
            let failure = await app.saveModelConfigEdit(
                originalName: "primary",
                draft: Self.draft(model: "gpt-4.1", apiKey: ""))
            #expect(failure == nil)
            let configs = await app.settings.modelConfigs
            #expect(configs[0].model == "gpt-4.1")
            #expect(configs[0].apiKey == "sk-old", "a blank key field erased the stored secret")
        }

        @Test("a typed key replaces the secret, stays staged across a refused save, and is never rendered")
        func typedKeyReplacesTheSecret() async {
            let app = Self.state(apiKey: "sk-old")
            await app.openModelConfigEdit("primary")

            // an empty name refuses the save: the typed key must survive it
            let refused = await app.saveModelConfigEdit(
                originalName: "primary",
                draft: Self.draft(name: "", model: "gpt-4.1", apiKey: "sk-new"))
            #expect(refused == .emptyName)

            let html = await app.settingsMain().markup.html
            #expect(!html.contains("sk-new"),
                    "a staged key was rendered back into the form")
            #expect(html.contains("a new key is staged"),
                    "the form does not say a key is staged")

            // fixing the name and saving again applies the staged key
            let saved = await app.saveModelConfigEdit(
                originalName: "primary",
                draft: Self.draft(name: "primary", model: "gpt-4.1", apiKey: ""))
            #expect(saved == nil)
            let configs = await app.settings.modelConfigs
            #expect(configs[0].apiKey == "sk-new", "the staged key was dropped")
        }

        @Test("the clear control removes the stored secret")
        func clearKeyRemovesTheSecret() async {
            let app = Self.state(apiKey: "sk-old")
            let failure = await app.saveModelConfigEdit(
                originalName: "primary",
                draft: Self.draft(clearAPIKey: true))
            #expect(failure == nil)
            let configs = await app.settings.modelConfigs
            #expect(configs[0].apiKey.isEmpty, "the stored key survived a clear")
        }

        // MARK: - in place

        @Test("saving edits the record in place and leaves its neighbours alone")
        func editsInPlace() async {
            let app = Self.state()
            let failure = await app.saveModelConfigEdit(
                originalName: "local",
                draft: Self.draft(name: "local", model: "qwen3", provider: "ollama",
                                  baseURL: "http://localhost:11434/v1",
                                  contextLength: 32_768, maxOutputTokens: 8_192))
            #expect(failure == nil)

            let configs = await app.settings.modelConfigs
            #expect(configs.map(\.name) == ["primary", "local"], "the edited record moved")
            #expect(configs[0].name == "primary" && configs[0].model == "gpt-4o",
                    "an unrelated record changed")
            #expect(configs[1].model == "qwen3")
            #expect(configs[1].contextLength == 32_768)
            #expect(configs[1].maxOutputTokens == 8_192)
            #expect(configs[1].apiKey.isEmpty)
            #expect(await app.editingModelConfig == nil, "the form stayed open after a successful save")
        }

        @Test("renaming repoints the active pick, every chat pin, and the auxiliary map")
        func renameRepointsPins() async {
            let app = Self.state()
            let failure = await app.saveModelConfigEdit(
                originalName: "primary",
                draft: Self.draft(name: "prod"))
            #expect(failure == nil)

            let settings = await app.settings
            #expect(settings.modelConfigs.first?.name == "prod")
            #expect(settings.activeConfig == "prod", "the active pick dangles after the rename")
            #expect(settings.sessionConfig["sess-a"] == "prod", "a chat pin dangles after the rename")
            #expect(settings.sessionConfig["sess-b"] == "local", "an unrelated pin moved")
            #expect(settings.auxiliaryModels["approval"] == "prod",
                    "an auxiliary route dangles after the rename")
        }

        @Test("a duplicate name is refused and nothing changes")
        func duplicateNameRefused() async {
            let app = Self.state()
            let before = await app.settings.modelConfigs
            let failure = await app.saveModelConfigEdit(
                originalName: "local",
                draft: Self.draft(name: "primary", model: "llama-3", provider: "ollama",
                                  baseURL: "http://localhost:11434/v1"))
            #expect(failure == .duplicateName("primary"))
            #expect(await app.settings.modelConfigs == before, "a refused save mutated the store")
        }

        @Test("invalid fields are refused before anything changes")
        func invalidFieldsRefused() async {
            let app = Self.state()
            let before = await app.settings.modelConfigs

            #expect(await app.saveModelConfigEdit(originalName: "primary", draft: Self.draft(name: "")) == .emptyName)
            #expect(await app.saveModelConfigEdit(originalName: "primary", draft: Self.draft(model: "")) == .emptyModel)
            #expect(await app.saveModelConfigEdit(originalName: "primary", draft: Self.draft(baseURL: "")) == .emptyBaseURL)
            #expect(await app.saveModelConfigEdit(originalName: "primary", draft: Self.draft(baseURL: "not a url")) == .invalidBaseURL)
            #expect(await app.saveModelConfigEdit(originalName: "primary", draft: Self.draft(baseURL: "ftp://host/v1")) == .invalidBaseURL)
            #expect(await app.saveModelConfigEdit(originalName: "gone", draft: Self.draft()) == .notFound)

            #expect(await app.settings.modelConfigs == before, "a refused save mutated the store")
        }

        // MARK: - the managed preset

        @Test("editing the managed configuration writes through to the main model block")
        func managedWritesThrough() async {
            let app = Self.managedState()
            let failure = await app.saveModelConfigEdit(
                originalName: "nemotron",
                draft: Self.draft(name: "ignored", model: "nemotron-next", provider: "vllm",
                                  baseURL: "http://new:8000/v1",
                                  contextLength: 4_096, maxOutputTokens: 512))
            #expect(failure == nil)

            let config = await app.arcConfig
            #expect(config.model.defaultModel == "nemotron-next",
                    "the main model block was not written — the next boot would revert the edit")
            #expect(config.model.provider == "vllm")
            #expect(config.model.baseURL == "http://new:8000/v1")
            #expect(config.model.contextLength == 4_096)
            #expect(config.model.maxOutputTokens == 512)

            let settings = await app.settings
            #expect(settings.modelConfigs.count == 1)
            #expect(settings.modelConfigs[0].name == "nemotron-next",
                    "the managed preset's name must follow its model")
            #expect(settings.modelConfigs[0].source == ConfigModelReconciler.managedSource)
            #expect(settings.activeConfig == "nemotron-next")
            #expect(settings.sessionConfig["s1"] == "nemotron-next")
        }

        @Test("the managed configuration's name field is read-only")
        func managedNameIsReadOnly() async {
            let app = Self.managedState()
            await app.openModelConfigEdit("nemotron")
            let html = await app.settingsMain().markup.html
            #expect(html.contains("readonly=\"\""), "the managed name field accepted a rename")
            #expect(html.contains("The name follows the model."))
        }

        @Test("the add form still renders when nothing is being edited")
        func addFormWhenIdle() async {
            let app = Self.state()
            let html = await app.settingsMain().markup.html
            #expect(html.contains("id=\"modelcfg-add-form\""))
            #expect(!html.contains("id=\"modelcfg-edit-form\""))
        }

        // MARK: - end to end

        @Test("the router opens the editor and saves it end to end")
        func routerRoundTrip() async {
            let app = Self.state()
            let router = EventRouter()
            let controller = Controller(app: app, push: { _ in })
            controller.wireGroup_settings_admin(router)

            _ = await router.dispatch(EventData(
                component: ComponentID("modelcfg-list"), event: "click",
                data: ["targetId": .string("mc-edit-" + enc("local"))]))
            #expect(await app.editingModelConfig == "local",
                    "the row's edit click did not open the form")

            _ = await router.dispatch(EventData(
                component: ComponentID("modelcfg-edit-form"), event: "submit",
                data: [
                    "mce-name": .string("local"),
                    "mce-model": .string("qwen3"),
                    "mce-provider": .string("ollama"),
                    "mce-baseurl": .string("http://localhost:11434/v1"),
                    "mce-apikey": .string(""),
                    "mce-ctx": .string("32768"),
                    "mce-maxtok": .string("8192"),
                ]))

            let configs = await app.settings.modelConfigs
            #expect(configs.count == 2)
            #expect(configs[1].model == "qwen3", "the submitted model did not land")
            #expect(configs[1].contextLength == 32_768)
            #expect(configs[1].maxOutputTokens == 8_192)
            #expect(await app.editingModelConfig == nil, "the form stayed open after saving")
        }

        @Test("the add path uses the same endpoint rule as the edit path")
        func addUsesTheSameEndpointRule() async {
            let app = Self.state()
            let router = EventRouter()
            let controller = Controller(app: app, push: { _ in })
            controller.wireGroup_settings_admin(router)

            func addEvent(name: String, baseURL: String) -> EventData {
                EventData(
                    component: ComponentID("modelcfg-add-form"), event: "submit",
                    data: [
                        "mc-name": .string(name),
                        "mc-model": .string("m"),
                        "mc-provider": .string("custom"),
                        "mc-baseurl": .string(baseURL),
                        "mc-apikey": .string(""),
                        "mc-ctx": .string(""),
                        "mc-maxtok": .string(""),
                    ])
            }

            _ = await router.dispatch(addEvent(name: "weird", baseURL: "ftp://host/v1"))
            #expect(await app.settings.modelConfigs.count == 2,
                    "a non-http endpoint was created, then could never be re-saved")

            _ = await router.dispatch(addEvent(name: "extra", baseURL: "https://example.com/v1"))
            #expect(await app.settings.modelConfigs.count == 3,
                    "a valid endpoint was refused")
        }
    }
}
