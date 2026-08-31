# ARC Agent — Vision Document

> **ARC** = Automatic Reference Counting. A nod to Swift's memory management model — deterministic, predictable, and efficient. This project applies the same philosophy to agent architecture: compile-time safety, minimal runtime overhead, and a precompiled binary that starts instantly and runs lean.

## Elevator Pitch

A precompiled, Swift-native AI agent harness — architecturally inspired by Hermes Agent, but built from the ground up for Swift's concurrency model, type system, and distribution story. Single binary, zero interpreter overhead, no npm dependency chain, instant startup.

## Guiding Principles

1. **Compile-time safety first.** The tool registry, schema generation, and configuration resolution should catch errors at build time, not runtime. Swift's type system is the primary defense against the class of bugs that plague Python agent frameworks (missing keys, wrong types, runtime import failures).

2. **Structured concurrency everywhere.** No thread pool executors, no `threading.Lock`, no `contextvars` workarounds. Swift actors and task groups are the concurrency primitives. The agent loop, tool dispatch, delegation, and gateway all run on Swift's cooperative async/await model.

3. **The core is a narrow waist.** Every tool schema is sent on every API call. New capabilities arrive as CLI commands, not core tool additions. The tool registry is closed at compile time for the built-in set. Plugins are deferred — the internal architecture must be proven before we add third-party variables to the engine.

4. **Deterministic startup and shutdown.** Swift Service Lifecycle manages the agent, gateway, cron scheduler, and kanban dispatcher as a tree of services. No ad-hoc daemon threads, no `atexit` handlers, no cleanup races.

5. **No npm.** Browser automation is optional and uses a native CDP client or a shelled-out headless browser CLI, not Playwright. Messaging platforms use their HTTP APIs directly, not JavaScript bridges.

6. **Hermes-compatible at the concept level, not the code level.** Same architectural patterns (tool registry, toolset intersection, credential pooling, delegation, kanban), but implemented in idiomatic Swift. No line-for-line translation.

7. **Protocols first, macros last.** Every abstraction starts as a protocol. Concrete types conform to protocols; protocols never depend on concrete types. Only after the protocol proves unwieldy in practice do we introduce a macro to compress the syntax. This ordering is not optional — macros that paper over a bad protocol design hide the problem, not fix it.

8. **Native web UI is a 1.0 requirement.** The project ships with a web-based user interface before version 1.0. How that UI is built is an open question — the author dislikes web technology and will not write JavaScript, CSS, or HTML by hand. The web UI must be generated, compiled from Swift, or delegated to a separate toolchain. This is a non-negotiable requirement; the approach is undecided and deferred.

## The Law of the Land

HEAR YE, HEAR YE. In this beautiful project, of which we are so proud, there shall be a law of the land, of which all agents and humans alike shall abide unconditionally at all times. THE LAW OF THE LAND IS SIMPLE, AND AS FOLLOWS:

**First Law — Swift Structured Concurrency, Without Exception.** Every fiber of this codebase shall run on `async`/`await`, every mutable state shall be guarded by an `actor`, every concurrent work stream shall be expressed as a `TaskGroup` or `AsyncStream`. There shall be no threads spawned by hand. There shall be no locks acquired by hand. There shall be no dispatch queues, no semaphores, no `@unchecked Sendable` cheats that subvert the compiler's concurrency guarantees. The compiler is our shield, and we shall not set it aside.

**Second Law — Swift Service Lifecycle, Without Exception.** Every long-lived component — the agent loop, the gateway, the cron scheduler, the kanban dispatcher — shall be a `Service` in a tree managed by `swift-service-lifecycle`. There shall be no ad-hoc daemon threads, no `atexit` cleanup handlers, no `DispatchMain()` calls that bypass the lifecycle framework. Startup is ordered, shutdown is graceful, and every service knows its place in the hierarchy.

These two laws are not goals. They are not aspirations. They are **requirements**. Code that violates them shall not be merged. Agents that generate code violating them shall be corrected. Humans that accept code violating them shall be reminded.

This is the contract. This is the foundation. Everything else is negotiable.

---

## The Information Vascular System

An agent framework is not a collection of features — it is a **vascular system** through which information flows. Messages arrive from platforms, flow through routing and session management, enter the agent loop, are enriched with memory and skills, pass through the LLM, dispatch to tools, and return as responses. Every junction in this flow is a vessel. Every vessel must be:

- **Patent** — no blockages, no dead ends, no dropped messages
- **Elastic** — handles pressure spikes (bursts of concurrent sessions) without rupture
- **Self-healing** — transient failures are retried, permanent failures are isolated
- **Observable** — you can see what's flowing, where it's backed up, and where it's leaking

The first five phases of this project built the vascular network — every pipe is connected end-to-end. The next phase hardens the vessels themselves. No new features. No new platforms. No third-party plugins that introduce unknown failure modes before the core plumbing is proven.

The roadmap below reflects this shift: from **feature expansion** to **vascular hardening**.

---

## Instance Relationships

A critical architectural property that must be clear at every level: which components are **singletons** (1 instance per process) and which are **N instances** (per-session, per-request, per-platform). The heap reference graph determines lifecycle, cleanup, and isolation.

```
Legend:
  [1]  = exactly 1 instance per process (singleton)
  [N]  = N instances, one per active session
  [P]  = P instances, one per platform adapter
  [*]  = unbounded (per-request, per-task, etc.)
```

### Top-Level Instance Graph

```
┌──────────────────────────────────────────────────────────────────┐
│                     GatewayService [1]                            │
│  (Service — owns the ServiceGroup, manages lifecycle)             │
│                                                                   │
│  ├── HTTPServerService [1]                                        │
│  │   (Service — Hummingbird HTTP server)                          │
│  │                                                                │
│  ├── TelegramAdapter [P]                                          │
│  │   (Service — one per platform with a bot token)                │
│  │                                                                │
│  ├── MCPServerAdapter [1]                                         │
│  │   (Service — MCP protocol server, stdio or TCP)                │
│  │   └── MCPServer [1]                                            │
│  │       └── DynamicMCPTool [*]                                   │
│  │           (one per ToolEntry in the registry)                  │
│  │                                                                │
│  ├── SessionRegistry [1] (actor)                                  │
│  │   └── SessionAgent [N] (actor, Service)                        │
│  │       └── ArcAgent [N] (actor)                                 │
│  │           ├── HTTPClient [N] (shared event loop group)         │
│  │           ├── OpenAICompatibleClient [N]                       │
│  │           ├── CompileTimeToolRegistry [1] (shared reference)   │
│  │           ├── DelegationManager [N]                            │
│  │           │   └── SubagentRecord [*] (per spawned child)       │
│  │           ├── ApprovalManager [N]                              │
│  │           ├── LMDBSessionStore [N] (per-session .mdb)          │
│  │           └── LMDBMemoryProvider [1] (shared global .mdb)      │
│  │                                                                │
│  └── DeliveryManager [1] (actor)                                  │
│      └── PlatformAdapter [P] references (weak, for routing)       │
│                                                                    │
│  Shared across all agents:                                        │
│  ├── CompileTimeToolRegistry [1] (struct, no heap)                │
│  ├── LMDBManager [1] (enum, no heap — static methods)             │
│  ├── LMDBMemoryProvider [1] (struct, shared global .mdb)          │
│  └── CredentialPool [1] (actor, shared credential rotation)       │
└──────────────────────────────────────────────────────────────────┘
```

### Heap Reference Rules

| Component | Count | Heap | Lifecycle |
|---|---|---|---|
| `GatewayService` | 1 | struct on stack | Process lifetime |
| `HTTPServerService` | 1 | class (Service) | Process lifetime |
| `TelegramAdapter` | P | class (Service) | Process lifetime |
| `MCPServerAdapter` | 1 | class (Service) | Process lifetime |
| `MCPServer` | 1 | class (Service) | Process lifetime |
| `SessionRegistry` | 1 | actor | Process lifetime |
| `SessionAgent` | N | actor (Service) | Session lifetime (idle → cancelled) |
| `ArcAgent` | N | actor | Same as SessionAgent |
| `HTTPClient` | N | class | Same as SessionAgent (shutdown in defer) |
| `LLMClient` | N | struct | Same as SessionAgent |
| `DelegationManager` | N | actor | Same as parent SessionAgent |
| `SubagentRecord` | * | struct on heap (actor state) | Child task lifetime |
| `DeliveryManager` | 1 | actor | Process lifetime |
| `CompileTimeToolRegistry` | 1 | struct (no heap) | Process lifetime |
| `LMDBManager` | 1 | enum (no heap) | Process lifetime |
| `CredentialPool` | 1 | actor | Process lifetime |

### Key Relationships

- **1 GatewayService → N SessionAgents.** The gateway creates session agents on demand. Each session agent is a child Service in the lifecycle tree. When idle, the Service Lifecycle framework cancels the agent's Task, `defer` blocks clean up the HTTPClient and per-session LMDB environment, and the agent removes itself from the registry.

- **1 SessionAgent → 1 ArcAgent.** Each session has exactly one agent actor. The agent is created by the session agent's `run()` method and lives for the session's duration.

- **1 ArcAgent → 1 HTTPClient.** Each agent creates its own HTTPClient. All HTTPClients share the `.singleton` event loop group — they are connection-pool objects, not threads. The HTTPClient is shut down in the session agent's `defer` block.

- **1 ArcAgent → 1 LMDBSessionStore.** Each session has its own `.mdb` file. The store is created per-session and the environment is closed when the session ends.

- **N ArcAgents → 1 LMDBMemoryProvider.** Memory is shared across all sessions (global `.mdb`). The memory provider is a struct — no heap allocation, no reference counting.

- **N ArcAgents → 1 CompileTimeToolRegistry.** The tool registry is a struct with no heap storage. All agents share the same tool definitions by value.

- **N ArcAgents → 1 CredentialPool.** Credentials are shared across all agents. The pool is an actor — credential exhaustion is tracked globally.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          GatewayService [1]                                  │
│              (Service — manages lifecycle of all child services)             │
│                                                                              │
│  ┌─────────────────────┐  ┌─────────────────────┐  ┌─────────────────────┐  │
│  │ HTTPServerService[1]│  │ TelegramAdapter [P] │  │ MCPServerAdapter[1] │  │
│  │ (Hummingbird)       │  │ (long polling)      │  │ (MCP protocol)      │  │
│  │ POST /v1/chat       │  │                     │  │ stdio / TCP         │  │
│  │ GET  /health        │  │                     │  │                     │  │
│  └─────────┬───────────┘  └─────────┬───────────┘  └─────────┬───────────┘  │
│            │                        │                        │              │
│            ▼                        ▼                        ▼              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                     SessionRegistry [1] (actor)                      │   │
│  │  Routing table: sessionID → SessionAgent (no cache, no sweep)        │   │
│  └────────────────────────────────┬─────────────────────────────────────┘   │
│                                   │                                          │
│                                   ▼                                          │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                    SessionAgent [N] (actor, Service)                  │   │
│  │  ┌────────────────────────────────────────────────────────────────┐  │   │
│  │  │  ArcAgent [N] (actor)                                         │  │   │
│  │  │  ┌──────────┐  ┌──────────┐  ┌────────────────────────────┐  │  │   │
│  │  │  │ Prompt   │  │ LLM Call │  │ Tool Dispatch              │  │  │   │
│  │  │  │ Builder  │─▶│ (OpenAI  │─▶│ (Registry + Handler)       │  │  │   │
│  │  │  │          │  │  Compat) │  │                            │  │  │   │
│  │  │  └──────────┘  └──────────┘  └────────────────────────────┘  │  │   │
│  │  └────────────────────────────────────────────────────────────────┘  │   │
│  │                                                                       │   │
│  │  Per-session resources (owned, shut down in defer):                   │   │
│  │  ├── HTTPClient [1] (.singleton event loop group)                     │   │
│  │  ├── OpenAICompatibleClient [1]                                       │   │
│  │  ├── DelegationManager [1] (actor)                                    │   │
│  │  ├── ApprovalManager [1]                                              │   │
│  │  └── LMDBSessionStore [1] (per-session .mdb)                         │   │
│  │                                                                       │   │
│  │  Shared (no heap, or shared actor):                                   │   │
│  │  ├── CompileTimeToolRegistry [1] (struct, no heap)                    │   │
│  │  ├── LMDBMemoryProvider [1] (struct, global .mdb)                     │   │
│  │  └── CredentialPool [1] (shared actor)                                │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  DeliveryManager [1] (actor)                                         │   │
│  │  Routes OutgoingMessage → correct PlatformAdapter by ChatTarget      │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Subsystem Architecture

### 1. Agent Loop (`ArcAgent` Actor) [N — one per active session]

**Purpose:** The central conversation loop that drives one user turn through the agent.

**State (held on the actor):**

```
ArcAgentState:
  - model: String
  - provider: String
  - baseURL: URL
  - apiKey: ***        // resolved at init, never stored
  - apiMode: APIMode        // chat_completions | messages_api | gemini | ...
  - enabledToolsets: Set<String>
  - disabledToolsets: Set<String>
  - validToolNames: [String]       // resolved after filtering
  - toolSchemas: [[String: Any]]   // OpenAI function-calling schema array
  - messageHistory: [Message]
  - sessionID: String
  - credentialPool: CredentialPool?     // shared actor reference [1]
  - memoryManager: MemoryManager
  - delegateDepth: Int
  - iterationBudget: IterationBudget
  - callbacks: AgentCallbacks      // progress, thinking, stream delta, etc.
```

**Turn loop (`runConversation`):**

```
1. Build system prompt
   - Agent identity + platform hints
   - Skills index (loaded from ~/.arc/skills/)
   - Memory (MEMORY.md + USER.md) — from shared LMDBMemoryProvider [1]
   - Context files (AGENTS.md, .cursorrules)
   - Ephemeral system prompt (if any)

2. Build turn context
   - Messages array (system + history + new user message)
   - Tool schemas (from registry, filtered by enabled/disabled toolsets)
   - Cache-control annotations for prompt caching

3. Call LLM
   - Select provider profile → resolve endpoint + auth + headers
   - Stream response or wait for complete
   - Handle errors: rate limit → backoff, auth failure → rotate credential,
     context overflow → compress and retry, model error → fallback chain

4. Parse response
   - If text response → return to caller
   - If tool_calls → go to step 5
   - If empty/error → retry with backoff

5. Dispatch tool calls
   - Parallelize independent calls (up to 8 concurrent workers)
   - Sequentialize dependent calls (same scope path)
   - Each call: look up handler in registry → execute → collect result
   - Handle errors: tool not found, handler throws, timeout

6. Append results to history
   - Assistant message (tool_calls)
   - Tool result messages
   - Go to step 2

7. Post-turn hooks
   - Memory write (if enabled) — to shared LMDBMemoryProvider [1]
   - Background review trigger
   - Session persistence flush — to per-session LMDBSessionStore [N]
```

**Key design decisions:**
- The agent is an **actor** so all state mutations are serialized. Tool handlers that need I/O run on the cooperative thread pool via `Task { await ... }`.
- Callbacks (progress display, streaming) use `AsyncStream` or `AsyncSequence` so the CLI/gateway can observe without blocking the loop.
- The iteration budget is checked before every LLM call and every tool dispatch.
- Each agent has its own HTTPClient [N]. All HTTPClients share the `.singleton` event loop group [1] — they are connection-pool objects, not threads.

---

### 2. Tool System

**Registry (`ToolRegistry`):** [1 — compile-time singleton, struct, no heap]

```swift
struct ToolEntry {
    let name: String
    let toolset: String
    let schema: JSONSchema          // OpenAI function-calling schema
    let handler: ToolHandler        // (JSON) async throws -> String
    let checkFn: ToolRequirementCheck?  // () -> Bool
    let requiresEnv: [String]
    let emoji: String?
}

typealias ToolHandler = @Sendable ([String: Any]) async throws -> String
typealias ToolRequirementCheck = @Sendable () -> Bool
```

**Registration pattern (compile-time):**

```swift
// Each tool file registers at module init via a static property
extension ToolRegistry {
    static let webSearch = ToolEntry(
        name: "web_search",
        toolset: "web",
        schema: .object(properties: [
            "query": .string(description: "Search query"),
            "limit": .integer(description: "Max results", default: 5)
        ]),
        handler: WebSearchHandler.handler,
        checkFn: { WebSearchProvider.isAvailable },
        requiresEnv: ["SEARCH_API_KEY"]
    )
}
```

**Toolset definitions (as registered in the codebase):**

```swift
let toolsetDefinitions: [String: ToolsetDef] = [
    "core": .init(description: "Core agent utilities", tools: ["memory", "skill_view"]),
    "file": .init(description: "File manipulation", tools: ["read_file", "write_file"]),
    "terminal": .init(description: "Shell commands", tools: ["terminal"]),
    "web": .init(description: "Web research tools", tools: ["web_search", "web_extract"]),
    "delegation": .init(description: "Subagent spawning and steering", tools: ["delegate_task", "list_children", "steer_child", "stop_child"]),
    "kanban": .init(description: "Multi-agent board", tools: ["kanban_create", "kanban_list", "kanban_show", "kanban_complete", "kanban_block"]),
    "profile": .init(description: "Bot profile management", tools: ["list_profiles", "get_profile", "create_profile", "delete_profile", "send_bot_message", "send_group_chat"]),
]
```

**22 tools across 7 toolsets.**

**Schema generation for LLM:**

The registry produces an array of OpenAI-compatible function-calling schemas:

```swift
func buildToolSchemas(enabled: Set<String>, disabled: Set<String>) -> [[String: Any]] {
    // 1. Resolve enabled toolsets to tool names
    // 2. Subtract disabled toolsets
    // 3. Run check_fn for each tool → filter unavailable
    // 4. Map to OpenAI schema format
}
```

---

### 3. Provider System [1 — shared configuration, no heap]

**ProviderProfile:**

```swift
struct ProviderProfile: Sendable {
    let name: String
    let apiMode: APIMode           // chat_completions | messages_api | gemini | ...
    let aliases: [String]
    let displayName: String
    let description: String
    let signupURL: String?
    let authType: AuthType         // apiKey | oauthDeviceCode | oauthExternal | copilot | awsSDK
    let baseURL: URL
    let modelsURL: URL?
    let defaultHeaders: [String: String]
    let fixedTemperature: Double?  // nil = use default, sentinel = omit entirely
    let defaultMaxTokens: Int?
    let supportsVision: Bool
    let supportsPromptCacheKey: Bool
    let fallbackModels: [String]
    let hostname: String
}
```

**Provider discovery:**

Providers are registered in two tiers (plugins deferred):
1. **Bundled** — compiled into the binary (OpenAI, Anthropic, OpenRouter, DeepSeek, Google, xAI, MiniMax, etc.)
2. **Config-defined** — custom endpoints defined in `config.yaml` with base URL + provider template

**API client architecture:**

```swift
protocol LLMClient {
    func complete(messages: [Message], tools: [[String: Any]]?) async throws -> LLMResponse
    func stream(messages: [Message], tools: [[String: Any]]?) -> AsyncThrowingStream<LLMDelta, Error>
}

struct OpenAICompatibleClient: LLMClient { ... }     // 95% of providers
struct AnthropicMessagesClient: LLMClient { ... }     // Anthropic-specific
struct GeminiClient: LLMClient { ... }                // Google-specific
```

The provider profile selects the client implementation. Most providers use `OpenAICompatibleClient` with different base URLs, headers, and auth.

**Credential pooling:** [1 — shared actor]

```swift
actor CredentialPool {
    struct Entry {
        let apiKey: ***
        var isExhausted: Bool
        var exhaustedUntil: Date?
    }
    
    private var entries: [Entry]
    private var currentIndex: Int
    
    func acquireLease() -> String?           // round-robin, skip exhausted
    func reportExhaustion(at index: Int)     // mark for cooldown
    func hasAvailable() -> Bool
}
```

---

### 4. Session Management [N — one per-session .mdb file]

ARC Agent uses **LMDB** for all persistent storage via a thin wrapper around the raw C API (`CLMDB`). Each session gets its own `.mdb` file. The global `.mdb` holds shared state (memory, skills index).

**Environment layout:**

```
~/.arc/
├── global.mdb              # Shared state (memory, skills index, config)
│   ├── memory              # user + agent memory entries
│   └── skills              # skills index
└── sessions/
    ├── <session-id>.mdb    # One per session — isolated, self-contained
    │   ├── meta            # session metadata (model, provider, timestamps)
    │   ├── headers         # fixed-size message headers (13 bytes each)
    │   └── bodies          # variable-length message bodies (JSON)
    ├── <session-id>.mdb
    └── ...
```

**Per-session .mdb contents (header/body split):**

```
┌─────────────────────────────────────────────────────────────┐
│  <session-id>.mdb                                            │
│  maxReaders: 8  |  maxDBs: 8  |  mapSize: 50MB             │
│                                                              │
│  meta database:                                              │
│    "session_meta" → JSON(SessionMeta)                        │
│      { createdAt, updatedAt, model, provider,                │
│        messageCount, totalTokens }                           │
│                                                              │
│  headers database (fixed-size, fast scan):                   │
│    key: UInt64 BE (8 bytes, sequence number)                 │
│    val: 13 bytes [role:UInt8][timestamp:UInt64][len:UInt32]  │
│                                                              │
│  bodies database (variable-length, loaded on demand):        │
│    key: UInt64 BE (8 bytes, sequence number)                 │
│    val: JSON(Message)                                        │
└─────────────────────────────────────────────────────────────┘
```

The header/body split means scanning N message headers reads exactly N × 13 bytes from the B-tree, regardless of message content size. Bodies are only decoded when the caller asks for a specific message or range of messages.

**Global .mdb contents:**

```
┌─────────────────────────────────────────────────────────────┐
│  global.mdb                                                  │
│  maxReaders: 64  |  maxDBs: 16  |  mapSize: 100MB           │
│                                                              │
│  memory database:                                            │
│    "user"  → "User prefers concise responses..."             │
│    "agent" → "Project uses pytest with xdist..."             │
└─────────────────────────────────────────────────────────────┘
```

**Why per-session .mdb over a single monolithic file:**

- **Session isolation** — one session with 10,000 turns doesn't slow down anything else
- **Natural FD management** — only active sessions have their `.mdb` open. Idle sessions are closed.
- **Trivial backup** — `cp <id>.mdb /backup/`. The file is always consistent (MVCC).
- **No compaction** — each session is finite. When the session ends, the file stops growing.
- **Parallel access** — different sessions don't contend on the same LMDB environment.

**Transaction pattern:**

```swift
// All operations use the thin CLMDB wrapper, bridged to async via GCD.
// LMDB operations are synchronous (memory-mapped) — they run on a GCD
// worker queue, not the cooperative thread pool.

func appendMessage(sessionID: String, message: Message) async throws {
    try await withCheckedThrowingContinuation { continuation in
        queue.async {
            do {
                let env = try LMDBManager.openSession(sessionID)
                defer { LMDB.envClose(env) }
                let txn = try LMDB.txnBeginWrite(env: env)
                defer { LMDB.txnAbort(txn) }
                // ... LMDB operations ...
                try LMDB.txnCommit(txn)
                continuation.resume()
            } catch { continuation.resume(throwing: error) }
        }
    }
}
```

---

### 5. Gateway / Messaging

**Architecture:**

```
GatewayService [1] (Service — manages all child services)
│
├── HTTPServerService [1] (Service — Hummingbird HTTP server)
│   ├── POST /v1/chat          — API server endpoint
│   └── GET  /health           — health check
│
├── TelegramAdapter [P] (Service — one per bot token)
│   └── Long-polling Bot API
│
├── MCPServerAdapter [1] (Service — MCP protocol server)
│   ├── StdioTransport (Claude Desktop)
│   └── TCPTransport (:8081, remote MCP clients)
│
├── SessionRegistry [1] (actor — routing table, no cache)
│   └── SessionAgent [N] (actor, Service — one per active session)
│       └── ArcAgent [N] (actor)
│           ├── HTTPClient [N] (.singleton event loop group)
│           ├── LMDBSessionStore [N] (per-session .mdb)
│           └── DelegationManager [N] (actor)
│
└── DeliveryManager [1] (actor — routes responses to platform adapters)
```

**PlatformAdapter protocol:**

```swift
protocol PlatformAdapter: Service {
    var name: String { get }
    func start() async throws
    func stop() async throws
    func send(message: OutgoingMessage, to: ChatTarget) async throws
    var incomingMessages: AsyncStream<IncomingMessage> { get }
}
```

**SessionRegistry [1] — routing table, not a cache:**

The registry holds a dictionary of active `SessionAgent` Services. It is NOT a cache — agents are live Services managed by the Service Lifecycle framework. LMDB is the single source of truth for all durable data.

```swift
actor SessionRegistry {
    private var agents: [String: SessionAgent] = [:]
    private var continuations: [String: AsyncStream<IncomingMessage>.Continuation] = [:]
    
    func getOrCreate(sessionID: String) -> AsyncStream<IncomingMessage>.Continuation
    func remove(sessionID: String)
}
```

**SessionAgent [N] — long-lived Service per session:**

Each session agent runs for the lifetime of one chat session. It receives messages via an `AsyncStream`, processes them through the agent loop, and sends responses back through the `DeliveryManager`. When idle (no messages arrive), the Service Lifecycle framework cancels the agent's Task, `defer` blocks clean up the HTTPClient and per-session LMDB environment, and the agent removes itself from the registry.

```swift
actor SessionAgent: Service {
    let sessionID: String
    private let incomingMessages: AsyncStream<IncomingMessage>
    private let deliveryManager: DeliveryManager  // [1] shared reference
    private let registry: SessionRegistry         // [1] shared reference
    
    func run() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        // ... create ArcAgent, set up client, process messages ...
        // defer: httpClient.shutdown(), registry.remove(sessionID)
    }
}
```

**DeliveryManager [1] — routes responses:**

```swift
actor DeliveryManager {
    private var adapters: [String: any PlatformAdapter] = [:]
    
    func register(adapter: any PlatformAdapter, for platform: String)
    func send(message: OutgoingMessage, to target: ChatTarget) async throws
}
```

---

### 6. Security / Approval System [N — one per ArcAgent]

```swift
actor ApprovalManager {
    enum Mode { case manual, smart, off }
    
    private let mode: Mode
    private var sessionStates: [String: SessionApprovalState]
    
    func needsApproval(command: String, sessionKey: String) async -> Bool
    func requestApproval(command: String, description: String, sessionKey: String) async -> ApprovalResult
}
```

**Dangerous command detection:**

```swift
let dangerousPatterns: [Regex] = [
    try! Regex("rm\\s+-rf"),
    try! Regex(">\\s*/dev/"),
    try! Regex("chmod\\s+777"),
    try! Regex(":(){ :|:& };:"),  // fork bomb
    // ... 50+ patterns
]

func detectDangerousCommand(_ command: String) -> DangerLevel? {
    for pattern in dangerousPatterns {
        if command.contains(pattern) {
            return .dangerous
        }
    }
    return nil
}
```

**Smart approval mode:**

Uses a lightweight auxiliary LLM call to classify the command as low-risk (auto-approve) or high-risk (prompt user). The auxiliary model is configurable and defaults to a cheap/fast model.

**YOLO mode:**

Frozen at process start from a command-line flag or environment variable. Cannot be toggled at runtime (prevents prompt-injection bypass).

---

### 7. Delegation System [N — one per ArcAgent]

```swift
actor DelegationManager {
    private var activeChildren: [SubagentID: SubagentRecord]
    
    func spawn(goal: String, context: String?, toolsets: [String]?,
               role: Role, maxIterations: Int) async throws -> SubagentHandle
    
    func list() -> [SubagentRecord]
    func steer(id: SubagentID, message: String) async throws
    func stop(id: SubagentID) async throws
}
```

**SubagentRecord:**

```swift
struct SubagentRecord: Sendable {
    let id: SubagentID
    let parentID: SubagentID?
    let goal: String
    let status: SubagentStatus     // running | completed | failed | interrupted
    let model: String
    let startedAt: Date
    var currentTool: String?
    var apiCallCount: Int
    var duration: TimeInterval?
}
```

**Child agent construction:**

The child inherits the parent's toolset configuration, then applies intersection with any explicit `toolsets` parameter, strips blocked tools (clarify, memory, send_message, cronjob), and preserves MCP toolsets. The child runs as a separate `Task` with its own `ArcAgent` instance.

**Heartbeat monitoring:**

A background task polls each child's activity every 30 seconds. If a child shows no progress for 15 idle cycles (450s) or 40 in-tool cycles (1200s), it's flagged as stale and interrupted.

**Steering:**

The parent can inject an out-of-band message into a running child via an `AsyncStream` that the child's agent loop checks at its next iteration boundary. The message appears as a user message in the child's context.

---

### 8. Cron Scheduler [1 — singleton Service]

```swift
struct CronJob: Codable, Sendable {
    let id: String
    let name: String?
    let schedule: CronSchedule     // enum: interval, cron, every, onetime
    let prompt: String
    let skills: [String]
    let model: String?
    let provider: String?
    let script: String?
    let enabled: Bool
    let workdir: String?
}

actor CronScheduler: Service {
    private var jobs: [String: CronJob]
    private var timers: [String: TimerHandle]
    private let jobStore: CronJobStore  // LMDB-backed
    
    func start() async throws
    func stop() async throws
    func create(job: CronJob) async throws
    func tick() async throws           // evaluate and fire due jobs
}
```

**Schedule parsing:**

```swift
enum CronSchedule: Codable, Sendable {
    case interval(seconds: TimeInterval)       // "30m", "2h"
    case cron(expression: String)              // "0 9 * * *"
    case every(phrase: String)                 // "every monday 9am"
    case onetime(date: Date)                   // ISO timestamp
}
```

**Job execution:**

Each tick evaluates all enabled jobs. Due jobs are dispatched as detached `Task` instances that run a full agent session with the job's prompt, skills, and model override. Results are delivered via the configured delivery target.

**Monitor mode:**

When a job has a monitor script, the script runs first. Its output is hashed. If the hash matches the previous run, the agent run is skipped entirely (silent tick). If it differs, the diff is injected into the agent's context as context for the run.

---

### 9. Kanban Board [1 — singleton Service]

```swift
struct KanbanTask: Codable, Sendable {
    let id: String
    let title: String
    let body: String
    let assignee: String
    let status: KanbanStatus       // triage | todo | ready | running | blocked | done | archived
    let priority: Int
    let parents: [String]
    let children: [String]
    let createdAt: Date
    let updatedAt: Date
}

actor KanbanBoard: Service {
    private let env: Environment
    
    func create(task: KanbanTask) async throws -> String
    func show(id: String) async throws -> KanbanTask
    func list(filter: KanbanFilter) async throws -> [KanbanTask]
    func complete(id: String, summary: String) async throws
    func block(id: String, reason: String) async throws
    func comment(id: String, body: String) async throws
    func link(parent: String, child: String) async throws
}
```

**Dispatcher:**

A background service that polls for `ready` tasks, atomically claims them (status → `running`), and spawns a worker agent with the task's goal, context, and assigned profile's toolset. Stale claims are reclaimed after a configurable timeout.

---

### 10. Memory System [1 — shared global .mdb]

```swift
protocol MemoryProvider: Sendable {
    func readMemory() async throws -> String
    func readUser() async throws -> String
    func appendMemory(_ text: String) async throws
    func replaceMemory(old: String, new: String) async throws
    func appendUser(_ text: String) async throws
    func replaceUser(old: String, new: String) async throws
}

struct LMDBMemoryProvider: MemoryProvider { ... }     // LMDB-backed [1]
struct FileMemoryProvider: MemoryProvider { ... }      // File-backed (legacy)
```

**Memory injection into system prompt:**

The agent reads memory from the shared `LMDBMemoryProvider` at the start of each turn and injects it into the system prompt. Memory is shared across all sessions — changes made in one session are visible in all others.

---

## Build Order & Milestones

The project has completed five feature-build phases and is now entering a **hardening phase**. The roadmap below reflects this shift: the vascular system is built; now we make it reliable, observable, and resilient.

### Phase A: Session & Data Integrity (the aorta)

*The foundation of a reliable agent framework is data that doesn't corrupt, leak, or disappear.*

- [x] **Persistent LMDB environment** — `LMDBSessionStore` is an actor holding a caller-owned environment for the session's lifetime (opened by `SessionAgent` and closed in its `Service.run()` teardown); the transient open/close-per-call path remains only for one-off operations and for `LMDBMemoryProvider`'s default global-env mode.
- [x] **Session lifecycle audit** — verify every `SessionAgent` cleanup path: HTTPClient shutdown, LMDB env close, registry removal on both happy path and error path. (Verified: `httpClient.shutdown()` in `run()` catch and tail, `defer { envClose }` on the session env, `registry.removeIfCurrent` on both paths.)
- [x] **Gateway response plumbing** — `POST /v1/chat` returns `"Message received"` immediately instead of the actual agent response. (Fixed: the handler now awaits the session agent's response stream and returns the real response text; the `"Message received"` fallback remains only for empty replies.)
- [ ] **Concurrent session isolation** — verify that N concurrent sessions don't interfere. LMDB per-session files provide isolation at the storage layer; verify the actor boundaries hold at the application layer. (`SessionRegistry`/`SessionAgent` are actors; no load test yet.)

**Deliverable:** Sessions survive process restarts. Gateway returns real responses. No resource leaks under load.

### Phase B: Context & Memory (the capillaries)

*The quality of an agent's output is bounded by the quality of its context. Crude heuristics waste tokens and lose signal.*

- [x] **Token counting** — `text.utf8.count / 4` is gone. The calibrated ``TokenCounter`` heuristic (content-classified per-character rates for code, whitespace, non-ASCII, plus model-specific calibration factors) drives auto-compression, prompt budgeting, and metrics.
- [ ] **Context compression** — auto-compress keeps the last N messages. (Truncation via `maxContextTokens` + `/compress` is implemented; no LLM-based summarization of middle turns yet.)
- [x] **Structured memory** — flat string append/replace. (Implemented as `StructuredMemoryProvider`: fact/procedure/profile distinction, content deduplication, and TTL eviction with compaction; covered by tests.)
- [x] **System prompt caching** — `cachedSystemPrompt` is invalidated on any history change. (Implemented via a version counter; the cache is rebuilt only when the version increments.)

**Deliverable:** Accurate token budgets. Smarter compression that preserves signal. Memory that doesn't grow unbounded.

### Phase C: Error Handling & Recovery (the immune system)

*Every component will fail. The system must degrade gracefully, not crash or silently corrupt.*

- [x] **LLM error classification audit** — verify `classifyError` handles all OpenAI error shapes: context length exceeded, rate limits, server errors, auth failures, content policy violations. Each should have a distinct recovery strategy. (Implemented: `classifyError` maps every shape to `retryable`/`permanent`/`contextOverflow`/`contentPolicyViolation` with distinct handling; covered by `TurnClassificationTests`.)
- [x] **Gateway-level session recovery** — if a `SessionAgent` crashes, the session is removed from the registry but the LMDB data is intact. (Implemented: the registry supervises crashes — identity-aware removal plus bounded auto-restart with 1s/2s/4s backoff, capping at 3 consecutive crashes; the budget resets on each explicit message. Fixing this also surfaced and fixed a same-path `EEXIST` collision: the global `.mdb` is now a single process-shared environment (`GlobalEnvironment` actor) instead of open/close-per-call.)
- [ ] **Structured tool errors** — tool handlers throw raw errors into the agent loop. Add structured error recovery: retry tool, skip tool, fall back to LLM, or surface to user. (`RetryHandler` currently covers LLM calls only.)
- [x] **Circuit breaker** — if the primary model fails and all fallbacks are exhausted, the agent returns an error string. Add a circuit breaker that prevents repeated calls to a failing endpoint and notifies the user. (Implemented: `CircuitBreaker` wired into `ArcAgent` with a 3-failure / 30s-open policy.)

**Deliverable:** Transient failures are invisible to the user. Permanent failures are isolated and reported. No silent data corruption.

### Phase D: Testing & Verification (the diagnostic system)

*Untested code is broken code. The vascular system must have monitors at every junction.*

- [ ] **Gateway tests** — `HTTPServerService` (health/UI/chat over a real socket), `DeliveryManager`, `WebSocketHandler`, and `SessionRegistry` are covered; `GatewayService`, `TelegramAdapter`, and `SessionAgent` are not directly.
- [x] **LMDB tests** — now covered by `LMDBRawTests`, `LMDBSessionStoreTests`, and `LMDBMemoryProviderTests` (session store: create/read/append/update/delete; memory: EACCES regression, roundtrip, replace; raw ops: named DBs, RO-txn semantics). All green.
- [x] **Integration tests** — mock-LLM tests now exercise the full agent pipeline (LLM → tool call → real registry handler → final response) on both completion and streaming paths (`AgentIntegrationTests`), and the gateway HTTP chokepoint is covered end-to-end over a real socket (`GatewayHTTPTests`).
- [x] **Concurrency tests** — concurrent `getOrCreate` races against one session serialize into a single coherent generation (`SessionRecoveryTests`). Actor-isolation and task-cancellation cases remain open.
- [x] **Fault injection tests** — `LMDBFaultInjectionTests` corrupt headers, bodies, and metadata and verify clean `SessionError` failures (no traps) plus repair-and-resume; corrupt is never silent corruption.

**Deliverable:** Test coverage on all critical paths. Confidence that the system survives real-world failure modes.

### Phase E: Performance & Observability (the vital signs)

*You can't fix what you can't see. You can't scale what you haven't measured.*

- [ ] **Streaming responses** — the LLM client streams deltas and the WebSocket path streams responses to the UI (including the one-response-per-message fix); the gateway HTTP path still returns the whole buffered reply.
- [ ] **Structured logging** — ad-hoc `print()` statements remain in the CLI; gateway and session-agent paths use `Logger` with per-step tracing (visible as `info` lines in server logs).
- [x] **Metrics** — counters exist and are wired into `ArcAgent` for tool calls, tokens, and errors by type (`Metrics.shared`); trace IDs and request correlation are not yet implemented.
- [ ] **LMDB performance** — measure read/write latency under load. The session path now holds a persistent environment for the agent's lifetime (no per-call open/close); the memory provider's global-env open/close-per-call path is unchanged. Benchmark and optimize.
- [ ] **Startup time** — measure and optimize cold-start latency for new session agents.

**Deliverable:** Observable, measurable system. Streaming responses. Performance baselines for all critical paths.

---

## Deferred Work

The following items are explicitly deferred until the vascular system is hardened:

| Item | Rationale |
|---|---|
| **Plugin system (`.dylib` bundles)** | Third-party code introduces unknown failure modes before the core plumbing is proven. MCP already provides a plugin-like mechanism for tool exposure. |
| **Additional platform adapters (Discord, Slack, WhatsApp)** | Each platform adds maintenance burden and API-specific failure modes. Telegram proves the adapter pattern; others can follow once the delivery pipeline is hardened. |
| **Browser automation** | Requires a native CDP client or shelled-out browser. Neither is trivial. Not needed for the core agent use case. |
| **Distribution (Homebrew, Docker)** | Premature before the binary is stable. Distribution is a Phase E (Polish) concern. |

---

## Key Architectural Decisions (Resolved)

These decisions have been made through implementation experience:

### 1. LMDB over file-based storage

The thin `CLMDB` wrapper replaced both the file-based session store and the QuickLMDB dependency. QuickLMDB v14's non-copyable types were incompatible with async Swift. The raw C API wrapper gives full control over transaction semantics and avoids dependency churn.

### 2. Per-session .mdb files over monolithic

Each session gets its own `.mdb` file. This provides natural isolation, parallel access, trivial backup, and no compaction requirement. The trade-off is more file descriptors under heavy load — acceptable given the target deployment scale.

### 3. Header/body split for message storage

Fixed-size 13-byte headers enable fast scanning of message metadata without loading full message bodies. Bodies are loaded on demand. This is a well-known pattern from database internals (Oracle, PostgreSQL TOAST).

### 4. Session agents as Services, not cached objects

Rather than caching agents in an LRU map with idle TTL, each session gets a live `SessionAgent` Service. The Service Lifecycle framework handles idle timeouts and cleanup natively. No sweep tasks, no eviction logic, no cache invalidation.

### 5. MCP over custom plugin system

The `swift-mcp` library provides a standardized protocol for tool exposure. Rather than building a custom `.dylib` plugin system, ARC Agent exposes its tools via MCP. Any MCP client (Claude Desktop, etc.) can use them. This defers the plugin problem without blocking tool extensibility.

### 6. Swift Regex over NSRegularExpression

Swift's built-in `Regex` type replaced `NSRegularExpression` to avoid Foundation's Objective-C bridging. The regex literals (`/pattern/`) are type-safe and checked at compile time.

---

## Resource Estimates

| Phase | Est. Tokens | Est. Time | Est. Cost (at $0.50/M tok) |
|---|---|---|---|
| Phase 1: Core Agent | 15-20M | 1-2 hours | $7.50-$10 |
| Phase 2: Production Readiness | 20-30M | 2-3 hours | $10-$15 |
| Phase 3: Multi-Agent | 25-40M | 3-4 hours | $12.50-$20 |
| Phase 4: Gateway | 30-50M | 4-6 hours | $15-$25 |
| Phase 5: MCP + Polish | 15-20M | 1-2 hours | $7.50-$10 |
| **Phase A: Session & Data Integrity** | 10-15M | 1-2 hours | $5-$7.50 |
| **Phase B: Context & Memory** | 15-20M | 2-3 hours | $7.50-$10 |
| **Phase C: Error Handling & Recovery** | 10-15M | 1-2 hours | $5-$7.50 |
| **Phase D: Testing & Verification** | 15-20M | 2-3 hours | $7.50-$10 |
| **Phase E: Performance & Observability** | 15-20M | 2-3 hours | $7.50-$10 |
| **Total (all phases)** | **170-250M** | **19-30 hours** | **$85-$125** |

These are generation-only estimates. Real-world costs include debugging iterations, design exploration, and testing — realistically **2-3x** the generation estimate, or **$250-$375** total for a complete v1.

---

## Phase F: Bot Mode (Multi-Profile Agent Roster)

*The vascular system is built and hardened. Now we populate it with multiple agents — each with its own identity, memory, and communication channels.*

### Architecture Overview

```
ProfileManager [1] (actor — LMDB-backed profile index)
│
├── Profile "default" [1] — The primary agent (backward-compatible)
├── Profile "researcher" [N] — Named bot with isolated config
├── Profile "builder" [N] — Named bot with isolated config
└── Profile "ops" [N] — Named bot with isolated config

BotMessagingService [1] (actor, Service — inter-agent message routing)
│
├── Canonical Chat per profile (persistent "Bot Chat" session)
├── Direct actor-to-actor delivery (no CLI invocation)
└── Activity tracking for "active now" presence strip

GroupChatManager [1] (actor — multi-agent coordination rooms)
│
└── GroupChatRoom [N] (actor — per-room state machine)
    ├── Round-robin turn execution
    ├── @mention routing
    ├── Epoch-based superseding
    └── Per-member watermark tracking

Web UI (compiled Swift DSL — no npm, no JS framework)
├── BotsPane (left sidebar — roster with avatars, search, groups)
├── RoutinesPane (right tile — per-bot cron jobs)
├── ActiveNowStrip (presence strip above roster)
├── NewAgentDialog (profile creation form)
└── BotChatHeader (profile-aware chat header)
```

### Key Design Decisions

#### 1. A bot IS a profile

The foundational insight from Hermes Bot Mode, adapted for ARC Agent. Each bot is a `Profile` struct with isolated config, memory, sessions, and SOUL.md. The `ProfileManager` actor manages the profile index in `global.mdb` (database: `profiles`).

#### 2. Per-profile LMDB isolation

```
~/.arc/
├── global.mdb
│   ├── memory       # default profile memory (backward compat)
│   └── profiles     # profile index: name → JSON(Profile)
└── profiles/
    └── <name>/
        ├── memory.mdb   # Per-profile memory
        └── sessions/    # Per-session .mdb files
```

This follows the existing per-session `.mdb` pattern exactly — same LMDB wrapper, same MVCC guarantees, same isolation properties.

#### 3. Direct actor-to-actor messaging (improvement over Hermes)

Where Hermes Bot Mode shells out to `hermes -p <target> chat ...` for bot-to-bot delivery, ARC Agent uses **direct actor method calls** through `BotMessagingService`. The message is routed into the recipient's canonical session via `SessionRegistry.getOrCreate()`. No CLI composition, no polling, no background process coordination.

#### 4. Push-based group chat (improvement over Hermes)

Where Hermes Bot Mode uses a 2-second poll loop with epoch-based superseding, ARC Agent's `GroupChatRoom` uses push-based delivery through `AsyncThrowingStream`. Each member turn is a direct `SessionRegistry.route()` call with an async stream for the response. Swift's cooperative timeout handles stuck members.

#### 5. Compiled web UI (improvement over Hermes)

Where Hermes Bot Mode is a 6,461-line JS/React plugin, ARC Agent's bot UI is compiled Swift using the existing `View` protocol DSL. No React, no JSX, no npm, no `package.json`. The avatar system generates SVG inline from Swift structs.

### Files

| File | Purpose |
|------|---------|
| `Profile/Profile.swift` | `Profile` struct, `AvatarConfig`, validation |
| `Profile/ProfileManager.swift` | `ProfileManager` actor, CRUD, LMDB persistence, SOUL generation |
| `Profile/BotMessagingService.swift` | `BotMessagingService` actor, inter-agent message routing |
| `Profile/GroupChatRoom.swift` | `GroupChatRoom` actor, `GroupChatManager`, turn protocol |
| `Tools/ProfileTools.swift` | Agent-facing tools: list, get, create, delete profiles, send messages |
| `WebUI/BotViews.swift` | `BotsPage`, `BotsPane`, `BotRow`, `BotAvatar`, `RoutinesPane`, dialogs |
| `WebUI/BotStyles.swift` | CSS rules for the bot mode UI |
| `WebUI/BotScripts.swift` | Extended JS runtime for bot interactions |

### Improvements Over Hermes Bot Mode

| Dimension | Hermes Bot Mode | ARC Agent |
|-----------|----------------|-----------|
| **Bot-to-bot delivery** | CLI invocation (`hermes -p ...`) | Direct actor method call |
| **Reply waiting** | Async via `notify_on_complete` | `AsyncThrowingStream` — inline await |
| **Group chat polling** | 2-second poll loop | Push-based via `SessionRegistry.route()` |
| **Avatar rendering** | JS `requestAnimationFrame` | Compiled Swift SVG DSL |
| **Storage** | Plugin storage + `ui_meta` RPC | LMDB (single source of truth) |
| **Profile isolation** | Filesystem directories | LMDB environments + Service Lifecycle |
| **Type safety** | None (JS) | Compile-time (Swift) |
| **Dependencies** | Hermes Desktop + plugin SDK | Single binary, zero new deps |
| **Web UI** | React plugin (6,461 lines JS) | Compiled Swift View DSL |

---

### Phase G: swift-log (the nervous system)

*You can't diagnose what you can't see. Print statements are not logging.*

The codebase has 40+ `print()` calls scattered across library code — in the agent loop, kanban dispatcher, cron scheduler, and WebSocket server. These are not user-facing output; they are diagnostic messages with no structure, no severity levels, no trace IDs, and no machine-parseability. When the system runs as a daemon (via `arc serve`), these `print()` calls go to stdout with no way to filter, route, or search them.

The `swift-log` package is already a dependency. `Logger(label:)` is already used in `GatewayService`. The work is to extend this pattern to every Service in the codebase.

- [ ] **Audit all `print()` calls** — distinguish user-facing CLI output (keep as `print()`) from diagnostic logging (replace with `Logger`)
- [ ] **Add `Logger` to every Service** — `ArcAgent`, `KanbanDispatcher`, `CronScheduler`, `WebSocketServer`, `TelegramAdapter`, `SessionAgent`
- [ ] **Replace diagnostic `print()`** with appropriate severity levels: `.debug`, `.info`, `.warning`, `.error`
- [ ] **Add trace IDs** — a `traceID: String` metadata field passed through the gateway pipeline for request correlation
- [ ] **Structured metadata** — attach session ID, profile name, model name, and error details to log statements

**Deliverable:** Every diagnostic message is a structured log statement with severity, trace ID, and context. `print()` is reserved for user-facing CLI output only.

---

## Resource Estimates

| Phase | Est. Tokens | Est. Time | Est. Cost (at $0.50/M tok) |
|---|---|---|---|
| Phase 1: Core Agent | 15-20M | 1-2 hours | $7.50-$10 |
| Phase 2: Production Readiness | 20-30M | 2-3 hours | $10-$15 |
| Phase 3: Multi-Agent | 25-40M | 3-4 hours | $12.50-$20 |
| Phase 4: Gateway | 30-50M | 4-6 hours | $15-$25 |
| Phase 5: MCP + Polish | 15-20M | 1-2 hours | $7.50-$10 |
| **Phase A: Session & Data Integrity** | 10-15M | 1-2 hours | $5-$7.50 |
| **Phase B: Context & Memory** | 15-20M | 2-3 hours | $7.50-$10 |
| **Phase C: Error Handling & Recovery** | 10-15M | 1-2 hours | $5-$7.50 |
| **Phase D: Testing & Verification** | 15-20M | 2-3 hours | $7.50-$10 |
| **Phase E: Performance & Observability** | 15-20M | 2-3 hours | $7.50-$10 |
| **Phase F: Bot Mode** | 20-30M | 2-3 hours | $10-$15 |
| **Phase G: swift-log** | 10-15M | 1-2 hours | $5-$7.50 |
| **Total (all phases)** | **200-295M** | **22-35 hours** | **$100-$147.50** |

These are generation-only estimates. Real-world costs include debugging iterations, design exploration, and testing — realistically **2-3x** the generation estimate, or **$300-$450** total for a complete v1.
