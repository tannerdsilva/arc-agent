import Foundation
import Testing
@testable import ArcAgentCore
import AsyncHTTPClient

@Suite("Auxiliary models")
struct AuxiliaryModelsTests {

    @Test("all Hermes auxiliary tasks exist with canonical keys, in Hermes order")
    func allTasks() {
        let expected = [
            "vision", "compression", "web_extract", "approval", "mcp",
            "title_generation", "memory_query_rewrite", "tts_audio_tags",
            "skills_hub", "triage_specifier", "kanban_decomposer",
            "profile_describer", "curator",
        ]
        #expect(AuxiliaryTask.allCases.map(\.key) == expected)
        #expect(AuxiliaryTask.allCases.count == 13)
        for task in AuxiliaryTask.allCases {
            #expect(!task.displayName.isEmpty)
            #expect(!task.detail.isEmpty)
        }
    }

    @Test("legacy arc-agent keys map to their Hermes-canonical tasks")
    func legacyAliases() {
        #expect(AuxiliaryTask(configKey: "title_gen") == .titleGeneration)
        #expect(AuxiliaryTask(configKey: "triage") == .triageSpecifier)
        #expect(AuxiliaryTask(configKey: "title_generation") == .titleGeneration)
        #expect(AuxiliaryTask(configKey: "triage_specifier") == .triageSpecifier)
    }

    @Test("overrides encode with Hermes field names (base_url/api_key)")
    func hermessFieldCoding() throws {
        let ov = AuxiliaryOverride(provider: "custom", model: "qwen-vl", baseURL: "http://x/v1", apiKey: "k")
        let data = try JSONEncoder().encode(ov)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: String]
        #expect(json?["model"] == "qwen-vl")
        #expect(json?["base_url"] == "http://x/v1")
        #expect(json?["api_key"] == "k")
        #expect(json?["baseURL"] == nil)
        // both spellings decode
        for text in [
            #"{"provider":"c","model":"m","base_url":"u","api_key":"k"}"#,
            #"{"provider":"c","model":"m","baseURL":"u","apiKey":"k"}"#,
        ] {
            let back = try JSONDecoder().decode(AuxiliaryOverride.self, from: Data(text.utf8))
            #expect(back.baseURL == "u")
            #expect(back.apiKey == "k")
        }
    }

    @Test("resolved() merges overrides over the main model, inheriting gaps")
    func resolution() {
        let main = ModelConfig(defaultModel: "gpt-4o", provider: "openai", baseURL: "https://api.openai.com/v1")
        var set = AuxiliaryModelSet()
        set.byTask[.vision] = AuxiliaryOverride(model: "qwen-vl", baseURL: "http://127.0.0.1:8000/v1")

        let routed = set.resolved(for: .vision, over: main, apiKey: "mainkey")
        #expect(routed.model == "qwen-vl")
        #expect(routed.provider == "openai")
        #expect(routed.baseURL == "http://127.0.0.1:8000/v1")
        #expect(routed.apiKey == "mainkey")                 // override has no key → main

        #expect(set.resolved(for: .titleGeneration, over: main).model == "gpt-4o")
        #expect(set.resolved(for: .titleGeneration, over: main).apiKey == "")

        // provider "auto" means "inherit the main provider" (Hermes behavior)
        set.byTask[.mcp] = AuxiliaryOverride(provider: "auto", model: "mcp-1")
        #expect(set.resolved(for: .mcp, over: main).provider == "openai")
    }

    @Test("router exposes hasOverride and resolves endpoints")
    func routerResolves() throws {
        let main = ModelConfig(defaultModel: "deepseek-v4-flash", provider: "custom", baseURL: "http://llm/v1")
        var set = AuxiliaryModelSet()
        set.byTask[.compression] = AuxiliaryOverride(model: "mini", baseURL: "http://aux/v1", apiKey: "auxkey")
        let router = AuxiliaryModelRouter(set: set, main: main, mainAPIKey: "mainkey")

        #expect(router.hasOverride(.compression))
        #expect(!router.hasOverride(.titleGeneration))

        let c = router.resolved(.compression)
        #expect(c.model == "mini")
        #expect(c.baseURL == "http://aux/v1")
        #expect(c.apiKey == "auxkey")

        let inherited = router.resolved(.titleGeneration)
        #expect(inherited.model == "deepseek-v4-flash")
        #expect(inherited.baseURL == "http://llm/v1")
        #expect(inherited.apiKey == "mainkey")

        // makeClient builds clients for both overridden and inherited tasks
        let hc = HTTPClient(eventLoopGroupProvider: .singleton)
        #expect(router.makeClient(task: .compression, httpClient: hc) != nil)
        #expect(router.makeClient(task: .titleGeneration, httpClient: hc) != nil)
        try hc.syncShutdown()
    }

    @Test("decodes a Hermes-shaped auxiliary block tolerantly and round-trips")
    func tolerantDecode() throws {
        let json = """
        {"vision":{"model":"qwen-vl","base_url":"http://x/v1"},
         "web_extract":{"provider":"custom"},
         "title_gen":{"model":"legacy"},
         "approval":{"model":"a1"},
         "unknown_task":{"model":"z"}}
        """
        let set = try JSONDecoder().decode(AuxiliaryModelSet.self, from: Data(json.utf8))
        #expect(set.byTask[.vision]?.model == "qwen-vl")
        #expect(set.byTask[.vision]?.baseURL == "http://x/v1")
        #expect(set.byTask[.webExtract]?.provider == "custom")
        // the legacy "title_gen" key maps onto the canonical task
        #expect(set.byTask[.titleGeneration]?.model == "legacy")
        #expect(set.byTask[.approval]?.model == "a1")
        #expect(!set.byTask.keys.contains { $0.key == "title_gen" })
        #expect(set.byTask.count == 4)               // legacy + 3 canonical; unknown ignored

        let encoded = try JSONEncoder().encode(set)
        let back = try JSONDecoder().decode(AuxiliaryModelSet.self, from: encoded)
        #expect(back == set)
    }

    @Test("ArcConfig carries an auxiliary block with tolerant decode")
    func arcConfigIntegration() throws {
        let json = #"{"model":{"defaultModel":"x"},"auxiliary":{"title_generation":{"model":"tiny"}}}"#
        let cfg = try JSONDecoder().decode(ArcConfig.self, from: Data(json.utf8))
        #expect(cfg.auxiliary.override(for: .titleGeneration)?.model == "tiny")
        #expect(cfg.auxiliary.override(for: .vision) == nil)
        #expect(cfg.auxiliary.resolved(for: .triageSpecifier, over: cfg.model).model == "x")
    }

    @Test("the live ~/.arc/config.json maps aux tasks to the Hermes oMLX layout")
    func liveConfigMirrorsHermes() throws {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arc/config.json")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(ArcConfig.self, from: data)
        else { return }  // no local config: nothing to assert

        let main = cfg.model

        // compression -> the Qwen model
        let comp = cfg.auxiliary.resolved(for: .compression, over: main)
        #expect(comp.model == "Qwen3.6-35B-A3B-OptiQ-4bit")

        // everything else Hermes routes to LFM2
        for task in [AuxiliaryTask.webExtract, .approval, .mcp, .titleGeneration,
                     .ttsAudioTags, .triageSpecifier, .kanbanDecomposer,
                     .profileDescriber, .curator, .skillsHub] {
            let r = cfg.auxiliary.resolved(for: task, over: main)
            #expect(r.model == "LFM2.5-8B-A1B-MLX-bf16", "\(task.key) should route to LFM2")
            #expect(r.baseURL == "http://127.0.0.1:8000/v1", "\(task.key) should hit local oMLX")
        }

        // main model stays the remote deepseek box; vision is unset (nothing)
        #expect(main.defaultModel == "deepseek-v4-flash-vision-exp")
        #expect(cfg.auxiliary.override(for: .vision) == nil)
    }
}

@Suite("Approval smart mode")
struct ApprovalSmartTests {

    @Test("smart mode decisions follow the LLM classifier")
    func classifierDrivesDecisions() async {
        let classifier: @Sendable (String) async -> DangerLevel? = { cmd in
            if cmd.contains("dcfs") { return .critical }
            if cmd.contains("destroy") { return .dangerous }
            if cmd.contains("suspicious") { return .suspicious }
            return .safe
        }
        let m = ApprovalManager(mode: .smart, classifier: classifier)

        let rCritical = await m.requestApproval(command: "dcfs /dev/disk0", description: "", sessionKey: "s1")
        #expect(rCritical == .denied)
        #expect(await m.needsApproval(command: "dcfs /dev/disk0", sessionKey: "s1"))

        let rDanger = await m.requestApproval(command: "destroy all data", description: "", sessionKey: "s2")
        #expect(rDanger == .requiresReview)

        let rSafe = await m.requestApproval(command: "ls -la", description: "", sessionKey: "s3")
        #expect(rSafe == .approved)
        #expect(!(await m.needsApproval(command: "ls -la", sessionKey: "s3")))
    }

    @Test("smart mode falls back to the regex detector when the classifier is unavailable")
    func fallback() async {
        let unavailable = ApprovalManager(mode: .smart, classifier: { _ in nil })
        // "rm -rf" is a dangerous regex pattern → review
        let rDanger = await unavailable.requestApproval(command: "rm -rf /etc", description: "", sessionKey: "s")
        #expect(rDanger == .requiresReview)
        // benign command → approved even without a classifier
        let rSafe = await unavailable.requestApproval(command: "echo hi", description: "", sessionKey: "s2")
        #expect(rSafe == .approved)
    }

    @Test("manual and off modes are unchanged by the classifier")
    func otherModes() async {
        let manual = ApprovalManager(mode: .manual, classifier: { _ in .safe })
        #expect(await manual.requestApproval(command: "echo hi", description: "", sessionKey: "s") == .requiresReview)
        let off = ApprovalManager(mode: .off, classifier: { _ in .critical })
        #expect(await off.requestApproval(command: "anything", description: "", sessionKey: "s") == .approved)
    }
}
