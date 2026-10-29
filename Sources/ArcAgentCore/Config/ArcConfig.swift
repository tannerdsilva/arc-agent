import Foundation
import Logging

/// The top-level configuration for ARC Agent.
///
/// Config is resolved in order of priority:
/// 1. CLI flags (highest)
/// 2. Environment variables
/// 3. `config.json` on disk
/// 4. Compiled-in defaults (lowest)
///
/// ## File Layout
/// ```
/// ~/.arc/
/// ├── config.json       # All non-secret settings
/// └── .env              # Secrets only (API keys, tokens)
/// ```
///
/// ## Design
///
/// This is a concrete `Codable` struct — no protocol needed. The config
/// format is stable and has no polymorphic behavior to abstract.
///
/// ## Partial Configs
///
/// Every section and field decodes **optionally against its default**, so a
/// config file that omits sections (e.g. only `model`/`agent`/`security`)
/// merges over the compiled-in defaults instead of failing to decode. This
/// matters because `saveConfig` writes the full shape, but hand-edited or
/// older config files often contain only a subset — and a decode failure
/// here would silently discard the *entire* file.
public struct ArcConfig: Codable, Sendable, Equatable {

    // MARK: - Model

    /// Model and provider configuration.
    public var model: ModelConfig

    /// Agent behavior configuration.
    public var agent: AgentConfig

    /// Legacy root-level tool-iteration limit (reference `max_turns` in flat
    /// configs). Read once at decode and lifted into ``limits``; never written
    /// back, so a rewritten file carries only the canonical section.
    public var max_turns: Int?

    /// The turn budgets, in one section: model rounds, per-tool calls, and
    /// wall-clock seconds. See ``Limits``.
    public var limits: Limits

    /// Legacy guardrail loop limits (the old `guardrails.toolLoopCap` key).
    /// Read once at decode and lifted into ``limits``; never written back.
    public var guardrails: GuardrailsConfig?

    /// Terminal tool configuration.
    public var terminal: TerminalConfig

    /// Delegation system configuration.
    public var delegation: DelegationConfig

    /// Memory system configuration.
    public var memory: MemoryConfig

    /// Security/approval configuration.
    public var security: SecurityConfig

    /// Tessera storage configuration. When set, sessions, memory, and the
    /// profile index are persisted as signed NOSTR events to a Tessera
    /// server instead of local files.
    public var tessera: TesseraConfig?
    /// Mixture-of-Agents configuration (reference `moa` config block).
    public var moa: MoAConfig

    /// Tool and skill enablement: the surface a session may use. Policy, not
    /// a web-UI preference — the CLI, the daemon and the web UI all read it.
    public var tools: ToolsConfig

    /// The storage medium this install runs on. Policy: the CLI, the daemon
    /// and the web UI all resolve it through ``StoreSelection``, so the
    /// backend the picker chooses is the backend the daemon uses. See
    /// ``StorageConfig``.
    public var storage: StorageConfig

    /// arc-parity auxiliary-model overrides (`auxiliary.<task>`), routing
    /// secondary tasks (vision, web extract, compression, approval, titles, …)
    /// to dedicated model configurations. Tasks without an override use the
    /// main model.
    public var auxiliary: AuxiliaryModelSet

    /// Tool-plugin enablement (reference `plugins.enabled` parity). `nil` = the
    /// key is absent (grandfathered: all discovered plugins are enabled);
    /// `[]` = explicitly none; a list = allow-list of plugin names.
    public var plugins: PluginsConfig

    /// Profile-based inbound routing (reference `profile_routes` /
    /// `multiplex_profiles`): routes inbound platform messages by
    /// platform/guild/channel/thread to a dedicated profile. Ignored unless
    /// `multiplexProfiles` is true.
    public var profileRouting: ProfileRoutingConfig

    /// Agent-powers lockdown (skills + profile files). All locks default to
    /// OFF (agent may create/edit); enabling any of them makes the dedicated
    /// tools refuse. See ``AgentPowersConfig``.
    public var agentPowers: AgentPowersConfig

    /// `processWatch` — scoped local process watching/control (plan B).
    public var processWatch: ProcessWatchConfig

    /// External MCP servers (reference top-level `mcp_servers`): name → launch config.
    public var mcpServers: [String: MCPServerConfig]

    /// Web capabilities (reference `web` block): search/extract backend selection.
    public var web: WebConfig

    /// Progressive tool disclosure (reference `tools.tool_search`).
    public var toolSearch: ToolSearchConfig

    /// Standing-goal loop configuration (reference `goals.max_turns`).
    public var goals: GoalsConfig
    /// Checkpoint/rollback safety net (reference `checkpoints.*` — opt-in).
    public var checkpoints: CheckpointsConfig?
    /// Event hooks: outbound webhook targets (reference `hooks.outbound`).
    public var hooks: HooksConfig = HooksConfig()
    /// Global default context recipe applied to sessions that carry no
    /// profile or session override. Nil = today's behavior (all segments on).
    public var contextDefaults: ContextRecipe?

    /// Configuration for web search/extract backends (reference `web` block).
    public struct WebConfig: Codable, Sendable, Equatable {
        /// Backend used by `web_search` (reference `web.search_backend`).
        public var searchBackend: String?
        /// Backend used by `web_extract` (reference `web.extract_backend`).
        public var extractBackend: String?
        /// Legacy catch-all (reference `web.backend`).
        public var backend: String?

        public init(searchBackend: String? = nil, extractBackend: String? = nil, backend: String? = nil) {
            self.searchBackend = searchBackend
            self.extractBackend = extractBackend
            self.backend = backend
        }

        /// Effective search backend: explicit > legacy.
        public var effectiveSearchBackend: String? {
            searchBackend ?? backend
        }

        private enum CodingKeys: String, CodingKey {
            case searchBackend = "search_backend"
            case extractBackend = "extract_backend"
            case backend
        }
    }

    // MARK: - Coding keys

    /// Explicit keys so the Herm...[truncated]

    /// Explicit keys so the arc-style `mcp_servers` underscore key can be
    /// decoded alongside the camelCase property names.
    private enum CodingKeys: String, CodingKey {
        case model
        case agent
        case max_turns
        case limits
        case guardrails
        case terminal
        case delegation
        case memory
        case security
        case tessera
        case moa
        case tools
        case storage
        case auxiliary
        case plugins
        case profileRouting
        case agentPowers
        case goals
        case mcpServers = "mcp_servers"
        case web
        case toolSearch = "tool_search"
        case checkpoints
        case hooks
        case contextDefaults = "context_defaults"
        case processWatch = "process_watch"
    }

    // MARK: - Init

    public init(
        model: ModelConfig = ModelConfig(),
        agent: AgentConfig = AgentConfig(),
        max_turns: Int? = nil,
        limits: Limits = Limits(),
        guardrails: GuardrailsConfig? = nil,
        terminal: TerminalConfig = TerminalConfig(),
        delegation: DelegationConfig = DelegationConfig(),
        memory: MemoryConfig = MemoryConfig(),
        security: SecurityConfig = SecurityConfig(),
        tessera: TesseraConfig? = nil,
        moa: MoAConfig = MoAConfig(),
        tools: ToolsConfig = ToolsConfig(),
        storage: StorageConfig = StorageConfig(),
        auxiliary: AuxiliaryModelSet = AuxiliaryModelSet(),
        plugins: PluginsConfig = PluginsConfig(),
        profileRouting: ProfileRoutingConfig = ProfileRoutingConfig(),
        agentPowers: AgentPowersConfig = AgentPowersConfig(),
        mcpServers: [String: MCPServerConfig] = [:],
        web: WebConfig = WebConfig(),
        toolSearch: ToolSearchConfig = ToolSearchConfig(),
        goals: GoalsConfig = GoalsConfig(),
        checkpoints: CheckpointsConfig? = nil,
        hooks: HooksConfig = HooksConfig(),
        contextDefaults: ContextRecipe? = nil,
        processWatch: ProcessWatchConfig = ProcessWatchConfig()
    ) {
        self.model = model
        self.agent = agent
        self.max_turns = max_turns
        self.limits = limits
        self.guardrails = guardrails
        self.terminal = terminal
        self.delegation = delegation
        self.memory = memory
        self.security = security
        self.tessera = tessera
        self.moa = moa
        self.tools = tools
        self.storage = storage
        self.auxiliary = auxiliary
        self.plugins = plugins
        self.profileRouting = profileRouting
        self.agentPowers = agentPowers
        self.mcpServers = mcpServers
        self.web = web
        self.toolSearch = toolSearch
        self.goals = goals
        self.checkpoints = checkpoints
        self.hooks = hooks
        self.contextDefaults = contextDefaults
        self.processWatch = processWatch
    }

    /// Decode each section independently, defaulting any that are absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.model = try container.decodeIfPresent(ModelConfig.self, forKey: .model) ?? ModelConfig()
        self.agent = try container.decodeIfPresent(AgentConfig.self, forKey: .agent) ?? AgentConfig()
        self.max_turns = try container.decodeIfPresent(Int.self, forKey: .max_turns)
        self.goals = try container.decodeIfPresent(GoalsConfig.self, forKey: .goals) ?? GoalsConfig()
        self.limits = try container.decodeIfPresent(Limits.self, forKey: .limits) ?? Limits()
        self.guardrails = try container.decodeIfPresent(GuardrailsConfig.self, forKey: .guardrails)
        self.terminal = try container.decodeIfPresent(TerminalConfig.self, forKey: .terminal) ?? TerminalConfig()
        self.delegation = try container.decodeIfPresent(DelegationConfig.self, forKey: .delegation) ?? DelegationConfig()
        self.memory = try container.decodeIfPresent(MemoryConfig.self, forKey: .memory) ?? MemoryConfig()
        self.security = try container.decodeIfPresent(SecurityConfig.self, forKey: .security) ?? SecurityConfig()
        self.tessera = try container.decodeIfPresent(TesseraConfig.self, forKey: .tessera)
        self.moa = try container.decodeIfPresent(MoAConfig.self, forKey: .moa) ?? MoAConfig()
        self.tools = try container.decodeIfPresent(ToolsConfig.self, forKey: .tools) ?? ToolsConfig()
        self.storage = try container.decodeIfPresent(StorageConfig.self, forKey: .storage) ?? StorageConfig()
        self.auxiliary = try container.decodeIfPresent(AuxiliaryModelSet.self, forKey: .auxiliary) ?? AuxiliaryModelSet()
        self.plugins = try container.decodeIfPresent(PluginsConfig.self, forKey: .plugins) ?? PluginsConfig()
        self.profileRouting = try container.decodeIfPresent(ProfileRoutingConfig.self, forKey: .profileRouting) ?? ProfileRoutingConfig()
        self.agentPowers = try container.decodeIfPresent(AgentPowersConfig.self, forKey: .agentPowers) ?? AgentPowersConfig()
        // reference top-level `mcp_servers` (underscored key → ``CodingKeys/mcpServers``).
        self.mcpServers = try container.decodeIfPresent([String: MCPServerConfig].self, forKey: .mcpServers) ?? [:]
        self.web = try container.decodeIfPresent(WebConfig.self, forKey: .web) ?? WebConfig()
        self.toolSearch = try container.decodeIfPresent(ToolSearchConfig.self, forKey: .toolSearch) ?? ToolSearchConfig()
        self.checkpoints = try container.decodeIfPresent(CheckpointsConfig.self, forKey: .checkpoints)
        self.hooks = try container.decodeIfPresent(HooksConfig.self, forKey: .hooks) ?? HooksConfig()
        self.contextDefaults = try container.decodeIfPresent(ContextRecipe.self, forKey: .contextDefaults)
        self.processWatch = try container.decodeIfPresent(ProcessWatchConfig.self, forKey: .processWatch)
            ?? ProcessWatchConfig()
        liftLegacyLimits()
    }

    /// Fold the pre-`limits` keys into the canonical section, once, at decode.
    ///
    /// Precedence is the one the old accessors encoded:
    /// `agent.max_turns` → root `max_turns` → `agent.maxIterations` for rounds,
    /// and `guardrails.toolLoopCap` for per-tool calls. The legacy keys are
    /// cleared afterwards so a rewrite emits only ``limits``.
    private mutating func liftLegacyLimits() {
        if limits.turns == nil {
            if let raw = agent.max_turns {
                limits.turns = Limit(raw: raw)
            } else if let raw = max_turns {
                limits.turns = Limit(raw: raw)
            }
        }
        if limits.perToolCalls == nil, let raw = guardrails?.toolLoopCap {
            limits.perToolCalls = Limit(raw: raw)
        }
        if limits.turnDuration == nil, let raw = agent.max_turn_duration {
            limits.turnDuration = Limit(raw: raw)
        }
        agent.max_turns = nil
        agent.max_turn_duration = nil
        max_turns = nil
        guardrails = nil
    }
}

// MARK: - Sub-Configs

/// Tool-plugin enablement (reference `plugins.enabled` parity). See
/// ``ArcConfig/plugins`` for the `nil` vs `[]` vs allow-list semantics.
public struct PluginsConfig: Codable, Sendable, Equatable {
    /// Allow-list of enabled plugin names. `nil` (key absent) means all
    /// discovered plugins are enabled (grandfathered); `[]` means none.
    public var enabled: [String]?

    public init(enabled: [String]? = nil) {
        self.enabled = enabled
    }

    /// Decode each field independently, defaulting any that are absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent([String].self, forKey: .enabled)
    }
}

// MARK: - Tools and skills (policy: the surface a session may use)

/// Tool and skill enablement (settings backbone, slice 3).
///
/// The surface a session gets is policy, not a web-UI preference: both lists
/// live in `~/.arc/config.json` so the CLI, the daemon and the web UI read the
/// same answer. Both are deny lists — a name that appears is removed from the
/// surface — and an absent or empty list disables nothing (the default).
public struct ToolsConfig: Codable, Sendable, Equatable {
    /// Toolsets removed from every session (`--toolsets` parity; the CLI also
    /// adds its flag and the bound profile's own sets to this list).
    public var disabledToolsets: [String]
    /// Skills removed from every session, by name.
    public var disabledSkills: [String]

    public init(disabledToolsets: [String] = [], disabledSkills: [String] = []) {
        self.disabledToolsets = disabledToolsets
        self.disabledSkills = disabledSkills
    }

    /// Decode each field independently, defaulting any that are absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.disabledToolsets = try container.decodeIfPresent([String].self, forKey: .disabledToolsets) ?? []
        self.disabledSkills = try container.decodeIfPresent([String].self, forKey: .disabledSkills) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case disabledToolsets
        case disabledSkills
    }

    /// The disabled toolsets as the `Set` every surface hands `ArcAgent`.
    public var disabledToolsetSet: Set<String> { Set(disabledToolsets) }

    /// The skills a session may carry: `discovered` minus the disabled names.
    ///
    /// `profileOverride` is a bound profile's own deny list. When present it
    /// *replaces* the global list — the precedence the UI has always had — it
    /// does not add to it.
    public func allowedSkills(from discovered: [Skill],
                              profileOverride: [String]? = nil) -> [Skill] {
        let disabled = Set(profileOverride ?? disabledSkills)
        return discovered.filter { !disabled.contains($0.name) }
    }
}

// MARK: - Storage medium (policy: the backend every surface runs on)

/// The storage-medium policy (settings backbone, slice 4).
///
/// `active` names the backend the CLI, the daemon and the web UI must agree
/// on — the one question that used to have two answers (`config.tessera`
/// presence for the daemon, `settings.activeStorage` for the UI).
///
/// - `"file"` — local files under `~/.arc`, even when a `tessera` block
///   exists: the block is a *credential*, not a switch, so switching to files
///   keeps it for a later switch back.
/// - `"tessera"` — the relay named by the `tessera` block. A config that
///   names Tessera without a block falls back to files and logs it; a policy
///   that cannot be honoured must never reach for a relay it cannot describe.
/// - `nil` (key absent) — the legacy inference that shipped before this key
///   existed: a `tessera` block means Tessera, no block means files. Every
///   config written before this slice therefore keeps its medium unchanged.
public struct StorageConfig: Codable, Sendable, Equatable {

    /// The declared medium: `"file"` | `"tessera"`; `nil` = legacy inference.
    public var active: String?

    public init(active: String? = nil) {
        self.active = active
    }

    /// Decode `active`, defaulting to `nil` (legacy inference) when absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.active = try container.decodeIfPresent(String.self, forKey: .active)
    }

    private enum CodingKeys: String, CodingKey {
        case active
    }
}

/// Model and provider configuration.
public struct ModelConfig: Codable, Sendable, Equatable {
    /// Default model to use.
    public var defaultModel: String
    /// Default provider name.
    public var provider: String
    /// Base URL override.
    public var baseURL: String?
    /// Context length for the default model.
    public var contextLength: Int?
    /// Explicit generation budget (reference `max_tokens` override). nil = use
    /// the registry's per-model max output.
    public var maxOutputTokens: Int?

    public init(
        defaultModel: String = "gpt-4o",
        provider: String = "openai",
        baseURL: String? = nil,
        contextLength: Int? = nil,
        maxOutputTokens: Int? = nil
    ) {
        self.defaultModel = defaultModel
        self.provider = provider
        self.baseURL = baseURL
        self.contextLength = contextLength
        self.maxOutputTokens = maxOutputTokens
    }

    /// Decode each field independently, defaulting any that are absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.defaultModel = try container.decodeIfPresent(String.self, forKey: .defaultModel) ?? ModelConfig().defaultModel
        self.provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? ModelConfig().provider
        self.baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
        self.contextLength = try container.decodeIfPresent(Int.self, forKey: .contextLength)
        self.maxOutputTokens = try container.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
    }
}

// MARK: - Hooks (reference `hooks.outbound`)

/// Event-hook configuration (reference `hooks:` block).
public struct HooksConfig: Codable, Sendable, Equatable {
    /// Outbound webhook targets (reference `hooks.outbound`).
    public var outbound: [OutboundWebhookTarget]

    public init(outbound: [OutboundWebhookTarget] = []) {
        self.outbound = outbound
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.outbound = try container.decodeIfPresent([OutboundWebhookTarget].self, forKey: .outbound) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case outbound
    }
}

// MARK: - Checkpoints (reference `checkpoints.*`, opt-in)

/// Checkpoint/rollback configuration (reference Hermes `checkpoints` block).
public struct CheckpointsConfig: Codable, Sendable, Equatable {
    /// Master switch. Default: false (opt-in, like Hermes v2).
    public var enabled: Bool?
    /// Max checkpoints per project (default 20; enforced on snapshot).
    public var maxSnapshots: Int?

    public init(enabled: Bool? = nil, maxSnapshots: Int? = nil) {
        self.enabled = enabled
        self.maxSnapshots = maxSnapshots
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        self.maxSnapshots = try container.decodeIfPresent(Int.self, forKey: .maxSnapshots)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case maxSnapshots
    }
}

// MARK: - Effective limits (one section, one meaning)

extension ArcConfig {

    /// The tool-iteration budget for a turn.
    ///
    /// `limits.turns` when configured; otherwise the legacy keys an in-memory
    /// config (or a config decoded before the lift) still carries, then the
    /// agent's own `maxIterations` default. Unlimited stays representable.
    public func turnLimit() -> Limit {
        if let configured = limits.turns { return configured }
        if let legacy = agent.max_turns { return Limit(raw: legacy) }
        if let legacy = max_turns { return Limit(raw: legacy) }
        return Limit(raw: agent.maxIterations)
    }

    /// The per-tool call cap.
    ///
    /// `limits.perToolCalls` when configured, else the legacy
    /// `guardrails.toolLoopCap`, else the compiled default.
    public func toolCallLimit() -> Limit {
        if let configured = limits.perToolCalls { return configured }
        if let legacy = guardrails?.toolLoopCap { return Limit(raw: legacy) }
        return .bounded(ToolGuardrails.defaultLoopCap)
    }

    /// The per-turn wall-clock budget. Absent or zero/negative means no cap —
    /// the default.
    public func turnDurationLimit() -> Limit {
        if let configured = limits.turnDuration { return configured }
        if let legacy = agent.max_turn_duration { return Limit(raw: legacy) }
        return .unlimited
    }

    /// The effective tool-iteration budget as an `Int` loop bound
    /// (`Int.max` when unlimited).
    public func effectiveMaxTurns() -> Int {
        turnLimit().effectiveValue
    }

    /// The effective per-tool call cap as an `Int` (`Int.max` when unlimited).
    ///
    /// Prefer ``toolCallLimit()``: an `Int` cannot tell "unlimited" from "a
    /// very large cap", which is how the anti-loop floor used to be disabled.
    public func effectiveToolLoopCap() -> Int {
        toolCallLimit().effectiveValue
    }

    /// The effective per-turn wall-clock budget in seconds; `nil` = unlimited.
    public func effectiveMaxTurnDuration() -> Int? {
        turnDurationLimit().bound
    }

    /// Effective per-turn wall-clock budget in seconds. `agent.max_turn_duration`
    /// when present and positive; `nil` (unlimited) otherwise — the default.
    public func effectiveMaxTurnDuration() -> Int? {
        guard let n = agent.max_turn_duration, n > 0 else { return nil }
        return n
    }
}

/// Agent behavior configuration.
public struct AgentConfig: Codable, Sendable, Equatable {
    /// Maximum iterations per conversation.
    public var maxIterations: Int
    /// reference `agent.max_turns` — tool-iteration budget override. Takes
    /// precedence over `maxIterations`; `0`/negative = unlimited.
    public var max_turns: Int?
    /// Maximum wall-clock duration per turn in seconds (reference
    /// `agent.max_turn_duration`). `nil` or `0`/negative = unlimited — the
    /// default; the user opts into a bound from the web UI settings.
    public var max_turn_duration: Int?
    /// Whether to persist sessions.
    public var persistSessions: Bool
    /// Whether to load skills on startup.
    public var loadSkills: Bool
    /// Reasoning effort passed to the provider (reference `agent.reasoning_effort`:
    /// "minimal"/"low"/"medium"/"high"/"max"). nil = provider default.
    public var reasoningEffort: String?
    /// Micro-compaction on/off (reference `compression.micro_compact`). Off by
    /// default; when on, one exchange is absorbed into a rolling summary after
    /// every completed turn (or every N turns, see ``microCompactEveryNTurns``).
    public var microCompactEnabled: Bool
    /// Micro-compaction cadence: one pass every N turns (reference
    /// `compression.micro_compact_every_n_turns`).
    public var microCompactEveryNTurns: Int
    /// Rolling-summary size that triggers a defrag pass (reference
    /// `compression.micro_compact_defrag_threshold_tokens`).
    public var microCompactDefragThresholdTokens: Int
    /// Personality overlay (`/personality <name>`): extra system-prompt text
    /// appended to the base prompt (reference `agent.system_prompt`). Empty =
    /// no overlay.
    public var systemPrompt: String
    /// Inject the "Finishing the job" task-completion guidance (arc parity:
    /// reference `agent.task_completion_guidance`). Default ON.
    public var taskCompletionGuidance: Bool
    /// Inject the "Parallel tool calls" batching guidance (arc parity:
    /// reference `agent.parallel_tool_call_guidance`). Default ON.
    public var parallelToolCallGuidance: Bool
    /// Inject tool-aware guidance for memory/session_search/skills tools
    /// (arc parity: reference `agent.tool_aware_guidance`). Default ON.
    public var toolAwareGuidance: Bool
    /// Inject tool-use-enforcement guidance (arc parity: reference
    /// `agent.tool_use_enforcement`) with per-model discipline notes.
    /// Default ON.
    public var toolUseEnforcement: Bool
    /// Named personality overlays (reference `agent.personalities`): each entry
    /// is either a plain string or `{description, system_prompt, tone, style}`.
    public var personalities: [String: PersonalityOverlay]
    /// Verify work at turn end (reference `verify_on_stop`): an aux verification
    /// pass is appended when enabled.
    public var verifyOnStop: Bool

    /// Run inline `!`cmd`` blocks in skills at load time (reference
    /// `skill_preprocessing`). Default ON.
    public var skillInlineCommands: Bool

    /// Background-review cadence: run an aux review every N tool calls
    /// (reference `background_review.after_tool_calls`). 0 = off.
    public var backgroundReviewAfter: Int

    /// Background-review call window (reference `background_review.window`).
    public var backgroundReviewWindow: Int

    public init(
        maxIterations: Int = 25,
        max_turns: Int? = nil,
        max_turn_duration: Int? = nil,
        persistSessions: Bool = true,
        loadSkills: Bool = true,
        reasoningEffort: String? = nil,
        microCompactEnabled: Bool = false,
        microCompactEveryNTurns: Int = 1,
        microCompactDefragThresholdTokens: Int = 2000,
        systemPrompt: String = "",
        taskCompletionGuidance: Bool = true,
        parallelToolCallGuidance: Bool = true,
        toolAwareGuidance: Bool = true,
        toolUseEnforcement: Bool = true,
        personalities: [String: PersonalityOverlay] = [:],
        verifyOnStop: Bool = false,
        skillInlineCommands: Bool = true,
        backgroundReviewAfter: Int = 0,
        backgroundReviewWindow: Int = 8
    ) {
        self.maxIterations = maxIterations
        self.max_turns = max_turns
        self.max_turn_duration = max_turn_duration
        self.persistSessions = persistSessions
        self.loadSkills = loadSkills
        self.reasoningEffort = reasoningEffort
        self.microCompactEnabled = microCompactEnabled
        self.microCompactEveryNTurns = microCompactEveryNTurns
        self.microCompactDefragThresholdTokens = microCompactDefragThresholdTokens
        self.systemPrompt = systemPrompt
        self.taskCompletionGuidance = taskCompletionGuidance
        self.parallelToolCallGuidance = parallelToolCallGuidance
        self.toolAwareGuidance = toolAwareGuidance
        self.toolUseEnforcement = toolUseEnforcement
        self.personalities = personalities
        self.verifyOnStop = verifyOnStop
        self.skillInlineCommands = skillInlineCommands
        self.backgroundReviewAfter = backgroundReviewAfter
        self.backgroundReviewWindow = backgroundReviewWindow
    }

    /// Decode each field independently, defaulting any that are absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.maxIterations = try container.decodeIfPresent(Int.self, forKey: .maxIterations) ?? AgentConfig().maxIterations
        self.max_turns = try container.decodeIfPresent(Int.self, forKey: .max_turns)
        self.max_turn_duration = try container.decodeIfPresent(Int.self, forKey: .max_turn_duration)
        self.persistSessions = try container.decodeIfPresent(Bool.self, forKey: .persistSessions) ?? AgentConfig().persistSessions
        self.loadSkills = try container.decodeIfPresent(Bool.self, forKey: .loadSkills) ?? AgentConfig().loadSkills
        self.reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        self.microCompactEnabled = try container.decodeIfPresent(Bool.self, forKey: .microCompactEnabled) ?? AgentConfig().microCompactEnabled
        self.microCompactEveryNTurns = try container.decodeIfPresent(Int.self, forKey: .microCompactEveryNTurns) ?? AgentConfig().microCompactEveryNTurns
        self.microCompactDefragThresholdTokens = try container.decodeIfPresent(Int.self, forKey: .microCompactDefragThresholdTokens) ?? AgentConfig().microCompactDefragThresholdTokens
        self.systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        self.taskCompletionGuidance = try container.decodeIfPresent(Bool.self, forKey: .taskCompletionGuidance) ?? true
        self.parallelToolCallGuidance = try container.decodeIfPresent(Bool.self, forKey: .parallelToolCallGuidance) ?? true
        self.toolAwareGuidance = try container.decodeIfPresent(Bool.self, forKey: .toolAwareGuidance) ?? true
        self.toolUseEnforcement = try container.decodeIfPresent(Bool.self, forKey: .toolUseEnforcement) ?? true
        self.personalities = try container.decodeIfPresent([String: PersonalityOverlay].self, forKey: .personalities) ?? [:]

        // Note: `CodingKeys` is synthesized from property names; use the
        // camelCase names that match the property declarations.
        self.verifyOnStop = try container.decodeIfPresent(Bool.self, forKey: .verifyOnStop) ?? false
        self.skillInlineCommands = try container.decodeIfPresent(Bool.self, forKey: .skillInlineCommands) ?? true
        self.backgroundReviewAfter = try container.decodeIfPresent(Int.self, forKey: .backgroundReviewAfter) ?? 0
        self.backgroundReviewWindow = try container.decodeIfPresent(Int.self, forKey: .backgroundReviewWindow) ?? 8
    }
}

/// Guardrail loop limits (`guardrails` block).
public struct GuardrailsConfig: Codable, Sendable, Equatable {
    /// Per-tool call cap before synthetic results (arc's default loop cap is
    /// 25). `0`/negative = unlimited (no synthetic limit for any tool).
    public var toolLoopCap: Int?

    public init(toolLoopCap: Int? = nil) {
        self.toolLoopCap = toolLoopCap
    }

    /// Decode each field independently, defaulting any that are absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.toolLoopCap = try container.decodeIfPresent(Int.self, forKey: .toolLoopCap)
    }
}

/// Terminal tool configuration.
public struct TerminalConfig: Codable, Sendable, Equatable {
    /// Default timeout in seconds.
    public var defaultTimeout: Int

    public init(defaultTimeout: Int = 180) {
        self.defaultTimeout = defaultTimeout
    }

    /// Decode each field independently, defaulting any that are absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.defaultTimeout = try container.decodeIfPresent(Int.self, forKey: .defaultTimeout) ?? TerminalConfig().defaultTimeout
    }
}

/// Delegation system configuration.
public struct DelegationConfig: Codable, Sendable, Equatable {
    /// Maximum concurrent child agents.
    public var maxConcurrentChildren: Int
    /// Per-child turn-loop iteration budget (tool + LLM rounds).
    public var maxTurns: Int
    /// Wall-clock budget in seconds for a child before it is cancelled.
    public var defaultTimeout: Int

    public init(
        maxConcurrentChildren: Int = 12,
        maxTurns: Int = 25,
        defaultTimeout: Int = 600
    ) {
        self.maxConcurrentChildren = maxConcurrentChildren
        self.maxTurns = maxTurns
        self.defaultTimeout = defaultTimeout
    }

    /// Decode each field independently, defaulting any that are absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.maxConcurrentChildren = try container.decodeIfPresent(Int.self, forKey: .maxConcurrentChildren) ?? DelegationConfig().maxConcurrentChildren
        self.maxTurns = try container.decodeIfPresent(Int.self, forKey: .maxTurns) ?? DelegationConfig().maxTurns
        self.defaultTimeout = try container.decodeIfPresent(Int.self, forKey: .defaultTimeout) ?? DelegationConfig().defaultTimeout
    }
}

/// Standing-goal configuration (reference `goals.max_turns`).
public struct GoalsConfig: Codable, Sendable, Equatable {
    /// Max continuation turns before auto-pause. Default 20.
    public var maxTurns: Int

    public init(maxTurns: Int = 20) {
        self.maxTurns = maxTurns
    }

    /// Decode each field independently, defaulting any that are absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.maxTurns = try container.decodeIfPresent(Int.self, forKey: .maxTurns) ?? GoalsConfig().maxTurns
    }
}

/// Memory system configuration.
public struct MemoryConfig: Codable, Sendable, Equatable {
    /// Whether memory is enabled.
    public var enabled: Bool

    public init(enabled: Bool = true) {
        self.enabled = enabled
    }

    /// Decode each field independently, defaulting any that are absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? MemoryConfig().enabled
    }
}

/// Security/approval configuration.
public struct SecurityConfig: Codable, Sendable, Equatable {
    /// The approval mode: `manual` | `smart` | `off` (see ``ApprovalMode``).
    ///
    /// This is the **only** approval setting. `off` is the YOLO policy — no
    /// prompts at all — and is frozen at process start.
    public var approvalMode: String
    /// Commands pre-exempted from approval ("Always allow" choices).
    /// Matched by exact, trimmed command string.
    public var alwaysAllowedCommands: [String]
    /// Tool policy: ordered allow/deny rules over tool invocations, enforced
    /// before dispatch.
    public var toolPolicy: ToolPolicyConfig

    public init(approvalMode: String = "manual",
                alwaysAllowedCommands: [String] = [], toolPolicy: ToolPolicyConfig = ToolPolicyConfig()) {
        self.approvalMode = approvalMode
        self.alwaysAllowedCommands = alwaysAllowedCommands
        self.toolPolicy = toolPolicy
    }

    /// Decode each field independently, defaulting any that are absent.
    ///
    /// The retired `yoloMode` boolean is ignored: `JSONDecoder` skips unknown
    /// keys, so an old config still decodes and simply carries no effect —
    /// `ARC_YOLO` is now the environment spelling of `approvalMode = "off"`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.approvalMode = try container.decodeIfPresent(String.self, forKey: .approvalMode) ?? SecurityConfig().approvalMode
        self.alwaysAllowedCommands = try container.decodeIfPresent([String].self, forKey: .alwaysAllowedCommands) ?? SecurityConfig().alwaysAllowedCommands
        self.toolPolicy = try container.decodeIfPresent(ToolPolicyConfig.self, forKey: .toolPolicy) ?? ToolPolicyConfig()
    }
}

// MARK: - Loading

/// Errors that can occur during config loading.
public enum ConfigError: Error, Sendable, CustomStringConvertible {
    case notFound(String)
    case parseError(String)
    case invalidValue(String)

    public var description: String {
        switch self {
        case .notFound(let path): return "Config file not found: \(path)"
        case .parseError(let message): return "Failed to parse config: \(message)"
        case .invalidValue(let message): return "Invalid config value: \(message)"
        }
    }
}

/// Load configuration from disk, merging with environment variables.
///
/// Resolution order:
/// 1. Start with compiled-in defaults
/// 2. Overlay values from `configURL` (if it exists)
/// 3. Overlay values from environment variables
///
/// - Parameter configURL: The config file URL. Defaults to `~/.arc/config.json`.
/// - Returns: The resolved configuration.

/// Load a `.env` file (`KEY=VALUE` per line; `#` comments and blank lines
/// ignored), returning a case-preserving map. Used to source secrets like the
/// tessera WireGuard private key without putting them in `config.json`.
func loadDotEnv(_ url: URL?) -> [String: String] {
    guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
    var out: [String: String] = [:]
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#") else { continue }
        guard let eq = line.firstIndex(of: "=") else { continue }
        let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
        var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.first == "\"", value.last == "\"" {
            value = String(value.dropFirst().dropLast())
        }
        out[key] = value
    }
    return out
}

/// Upsert `KEY=VALUE` into a `.env` file, preserving other lines/comments.
/// Creates the file (mode 0o600) if missing. For the secrets file only.
func setDotEnvKey(_ url: URL, key: String, value: String) throws {
    let existing = try? String(contentsOf: url, encoding: .utf8)
    var lines = existing?.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) ?? []
    var replaced = false
    for i in lines.indices {
        let t = lines[i].trimmingCharacters(in: .whitespaces)
        if t.hasPrefix(key + "=") {
            lines[i] = "\(key)=\(value)"
            replaced = true
            break
        }
    }
    if !replaced {
        if let last = lines.last, !last.isEmpty { lines.append("") }
        lines.append("\(key)=\(value)")
    }
    var content = lines.joined(separator: "\n")
    if !content.hasSuffix("\n") { content += "\n" }
    try Data(content.utf8).write(to: url, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

public func loadConfig(from configURL: URL? = nil) -> ArcConfig {
    let resolvedURL = configURL ?? ArcHome.config
    let declared: ArcConfig
    do {
        declared = try ConfigurationStore.readDeclared(resolvedURL)
    } catch {
        // one-shot CLI commands stay tolerant of a corrupt file — but the
        // failure is loud, because every model/provider choice is ignored.
        Logger(label: "com.arc-agent.config").error(
            "Failed to parse \(resolvedURL.path); using default configuration: \(error)"
        )
        declared = ArcConfig()
    }
    return ConfigurationStore.resolve(
        declared,
        environment: ProcessInfo.processInfo.environment,
        url: resolvedURL
    )
}

/// Apply environment overrides to a declared configuration.
///
/// This is the one resolution implementation: ``loadConfig`` and
/// ``ConfigurationStore`` both call it, so a one-shot command and the web UI
/// can never disagree about what an environment variable means.
func applyEnvironmentOverrides(
    _ config: ArcConfig,
    environment: [String: String],
    dotenv: [String: String]
) -> ArcConfig {
    var config = config

    if let model = environment["ARC_MODEL"] {
        config.model.defaultModel = model
    }
    if let provider = environment["ARC_PROVIDER"] {
        config.model.provider = provider
    }
    if let baseURL = environment["ARC_BASE_URL"] {
        config.model.baseURL = baseURL
    }
    // Approval policy. One key, two spellings: `ARC_APPROVAL_MODE` names a
    // mode, `ARC_YOLO` is the legacy boolean whose only meaning was "off".
    // Precedence: the variable that NAMES a mode wins — an explicit
    // `ARC_APPROVAL_MODE=manual` is a more specific instruction than a stale
    // `ARC_YOLO` in a shell profile, and must not be overridden by it.
    if let approvalMode = environment["ARC_APPROVAL_MODE"] {
        config.security.approvalMode = approvalMode
    } else if environment["ARC_YOLO"] != nil {
        // presence, not truthiness — `ARC_YOLO=0` still exported means the
        // operator opted in, exactly as the old boolean read it.
        config.security.approvalMode = ApprovalMode.off.rawValue
    }

    // Tessera storage overrides. Any ARC_TESSERA_* variable activates the
    // tessera backend; unset fields keep whatever config.json declared.
    let tesseraIP = environment["ARC_TESSERA_SERVER_IP"]
    let tesseraPort = environment["ARC_TESSERA_SERVER_PORT"]
    let tesseraServerPub = environment["ARC_TESSERA_SERVER_PUBLIC_KEY"]
    let tesseraClientPriv = environment["ARC_TESSERA_PRIVATE_KEY"]
        ?? dotenv["ARC_TESSERA_PRIVATE_KEY"]
    if tesseraIP != nil || tesseraPort != nil || tesseraServerPub != nil || tesseraClientPriv != nil {
        var t = config.tessera ?? TesseraConfig(
            serverIP: "127.0.0.1", serverPort: 51820,
            serverPublicKey: "", myPrivateKey: "", application: 1
        )
        if let tesseraIP { t.serverIP = tesseraIP }
        if let tesseraPort, let p = Int(tesseraPort) { t.serverPort = p }
        if let tesseraServerPub { t.serverPublicKey = tesseraServerPub }
        if let tesseraClientPriv { t.myPrivateKey = tesseraClientPriv }
        if let app = environment["ARC_TESSERA_APPLICATION"], let a = UInt16(app) {
            t.application = a
        }
        config.tessera = t
    }

    return config
}

/// Save configuration to disk.
///
/// - Parameters:
///   - config: The configuration to save.
///   - configURL: The config file URL. Defaults to `~/.arc/config.json`
///     (`$ARC_HOME/config.json` when `ARC_HOME` is set).
/// - Throws: If the file cannot be written.
public func saveConfig(_ config: ArcConfig, to configURL: URL? = nil) throws {
    let resolvedURL = configURL ?? ArcHome.config
    let configDir = resolvedURL.deletingLastPathComponent()

    // never overwrite a file that cannot be decoded: a caller that read the
    // file tolerantly (`loadConfig` on a corrupt file returns defaults) would
    // otherwise replace the user's whole configuration with compiled values.
    if FileManager.default.fileExists(atPath: resolvedURL.path) {
        _ = try ConfigurationStore.readDeclared(resolvedURL)
    }

    try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    // Secrets never go into config.json. Pull the tessera WireGuard private
    // key out and persist it to ~/.arc/.env instead; config.json keeps only
    // the non-secret fields (ip/port/public-key/application) with an empty key.
    var out = config
    let secret: String?
    if let priv = out.tessera?.myPrivateKey, !priv.isEmpty {
        secret = priv
        out.tessera?.myPrivateKey = ""
    } else {
        secret = nil
    }
    let data = try enc.encode(out)
    try data.write(to: resolvedURL, options: .atomic)
    if let secret {
        try setDotEnvKey(resolvedURL.deletingLastPathComponent().appendingPathComponent(".env"),
                         key: "ARC_TESSERA_PRIVATE_KEY", value: secret)
    }
    // The config file no longer carries the private key, so restrict perms.
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: resolvedURL.path)
}

/// Resolve the plugin allow-list from `~/.arc/config.json` (reference
/// `plugins.enabled` parity).
///
/// - Returns: `nil` when the `plugins.enabled` key is absent — callers treat
///   that as "all discovered plugins are enabled" (grandfathered); an empty
///   set means none are enabled; otherwise the concrete allow-list.
public func pluginAllowList(from configURL: URL? = nil) -> Set<String>? {
    loadConfig(from: configURL).plugins.enabled.map { Set($0) }
}


// MARK: - Agent Powers (lockdown)

/// Lockdown configuration for what the agent may create/edit.
///
/// - `skillsManage`: when false the agent cannot create or edit skills at
///   all (`skill_creation`/`skill_edit` refuse; general write tools refuse
///   paths under the skills directory).
/// - `lockedSkills`: per-skill locks — the named skills cannot be edited
///   (creation of an existing name is also refused).
/// - `profileEdit`: when false the agent cannot modify MEMORY.md, USER.md,
///   SOUL.md or AGENTS.md at all.
/// - `lockedProfileFiles`: per-file locks among `"memory"`, `"user"`,
///   `"soul"`, `"agents"`.
public struct AgentPowersConfig: Codable, Sendable, Equatable {
    public var skillsManage: Bool
    public var lockedSkills: [String]
    public var profileEdit: Bool
    public var lockedProfileFiles: [String]

    public init(
        skillsManage: Bool = true,
        lockedSkills: [String] = [],
        profileEdit: Bool = true,
        lockedProfileFiles: [String] = []
    ) {
        self.skillsManage = skillsManage
        self.lockedSkills = lockedSkills
        self.profileEdit = profileEdit
        self.lockedProfileFiles = lockedProfileFiles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.skillsManage = try container.decodeIfPresent(Bool.self, forKey: .skillsManage) ?? true
        self.lockedSkills = try container.decodeIfPresent([String].self, forKey: .lockedSkills) ?? []
        self.profileEdit = try container.decodeIfPresent(Bool.self, forKey: .profileEdit) ?? true
        self.lockedProfileFiles = try container.decodeIfPresent([String].self, forKey: .lockedProfileFiles) ?? []
    }
}
