# ARC Agent — Vision Document

> **ARC** = Automatic Reference Counting. A nod to Swift's memory management model — deterministic, predictable, and efficient. This project applies the same philosophy to agent architecture: compile-time safety, minimal runtime overhead, and a precompiled binary that starts instantly and runs lean.

## Elevator Pitch

A precompiled, Swift-native AI agent harness — architecturally inspired by Hermes Agent, but built from the ground up for Swift's concurrency model, type system, and distribution story. Single binary, zero interpreter overhead, no npm dependency chain, instant startup.

## Guiding Principles

1. **Compile-time safety first.** The tool registry, schema generation, and configuration resolution should catch errors at build time, not runtime. Swift's type system is the primary defense against the class of bugs that plague Python agent frameworks (missing keys, wrong types, runtime import failures).

2. **Structured concurrency everywhere.** No thread pool executors, no `threading.Lock`, no `contextvars` workarounds. Swift actors and task groups are the concurrency primitives. The agent loop, tool dispatch, delegation, and gateway all run on Swift's cooperative async/await model.

3. **The core is a narrow waist.** Every tool schema is sent on every API call. New capabilities arrive as plugins or CLI commands, not core tool additions. The tool registry is closed at compile time for the built-in set, extensible at runtime via plugin bundles.

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

## Protocols-First Design

This project has a strict ordering for how abstractions are built:

**Step 1 — Protocol.** Every abstraction starts as a protocol. The protocol captures the contract without committing to any implementation strategy. It lives in its own file, documented with the semantics of each requirement.

**Step 2 — Concrete types.** Structs and classes conform to protocols. Multiple conformances are encouraged — a protocol with one implementation is often a sign the abstraction isn't right yet. Protocols never depend on concrete types; concrete types depend on protocols.

**Step 3 — Macros (only when needed).** Only after the protocol proves unwieldy in practice — too much boilerplate, too many conformances, too much repetition — do we introduce a macro to compress the syntax. The macro is a convenience, not a design tool. It must not hide the protocol's contract.

This ordering is load-bearing. A macro that papers over a bad protocol design hides the problem and makes it harder to fix. The protocol must be right first. If the protocol is right, the macro is optional. If the protocol is wrong, no macro can save it.

### Examples of the pattern

- `ToolRegistry` is a protocol. `CompileTimeToolRegistry` and `PluginToolRegistry` are concrete conformances. A `#tool` macro may eventually generate the boilerplate for registering a tool, but only after the registration API is proven stable.

- `LLMClient` is a protocol. `OpenAICompatibleClient`, `AnthropicMessagesClient`, and `GeminiClient` are concrete conformances. No macro needed — the protocol is the right level of abstraction.

- `SessionStore` is a protocol. `LMDBStore` is a concrete conformance. If a second implementation emerges (e.g. `JSONFileSessionStore` for debugging), the protocol is validated. If not, the protocol may be collapsed into the concrete type.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                     CLI / Gateway                        │
│  (Swift Argument Parser / Hummingbird HTTP server)       │
└──────────────────────┬──────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────┐
│                   Agent Loop (Actor)                     │
│  ┌──────────┐  ┌──────────┐  ┌──────────────────────┐  │
│  │ Prompt   │  │ LLM Call │  │ Tool Dispatch        │  │
│  │ Builder  │─▶│ (OpenAI  │─▶│ (Registry + Handler) │  │
│  │          │  │  Compat) │  │                      │  │
│  └──────────┘  └──────────┘  └──────────────────────┘  │
└──────────────────────┬──────────────────────────────────┘
                       │
        ┌──────────────┼──────────────┐
        ▼              ▼              ▼
┌──────────────┐ ┌──────────┐ ┌──────────────┐
│ Tool Registry│ │ Provider │ │ Session      │
│ (Compile-time│ │ Profiles │ │ Store (LMDB) │
│  + Plugins)  │ │          │ │              │
└──────────────┘ └──────────┘ └──────────────┘
        │              │              │
        ▼              ▼              ▼
┌──────────────┐ ┌──────────┐ ┌──────────────┐
│ Delegation   │ │ Credential│ │ Memory       │
│ (Subagent    │ │ Pool     │ │ Manager      │
│  Spawning)   │ │ (Actor)  │ │              │
└──────────────┘ └──────────┘ └──────────────┘
        │                             │
        ▼                             ▼
┌──────────────┐              ┌──────────────┐
│ Kanban Board │              │ Skills       │
│ (LMDB)      │              │ System       │
└──────────────┘              └──────────────┘
```

---

## Subsystem Architecture

### 1. Agent Loop (`ArcAgent` Actor)

**Purpose:** The central conversation loop that drives one user turn through the agent.

**State (held on the actor):**

```
ArcAgentState:
  - model: String
  - provider: String
  - baseURL: URL
  - apiKey: String?        // resolved at init, never stored
  - apiMode: APIMode        // chat_completions | messages_api | gemini | ...
  - enabledToolsets: Set<String>
  - disabledToolsets: Set<String>
  - validToolNames: [String]       // resolved after filtering
  - toolSchemas: [[String: Any]]   // OpenAI function-calling schema array
  - messageHistory: [Message]
  - sessionID: String
  - sessionDB: SessionDatabase
  - credentialPool: CredentialPool?
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
   - Memory (MEMORY.md + USER.md)
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
   - Memory write (if enabled)
   - Background review trigger
   - Session persistence flush
```

**Key design decisions:**
- The agent is an **actor** so all state mutations are serialized. Tool handlers that need I/O run on the cooperative thread pool via `Task { await ... }`.
- Callbacks (progress display, streaming) use `AsyncStream` or `AsyncSequence` so the CLI/gateway can observe without blocking the loop.
- The iteration budget is checked before every LLM call and every tool dispatch.

---

### 2. Tool System

**Registry (`ToolRegistry`):**

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

Or via a result-builder macro:

```swift
#tool("web_search", toolset: "web", requiresEnv: "SEARCH_API_KEY") { args in
    let query: String = args["query"]
    let limit: Int = args["limit"] ?? 5
    return try await WebSearch.search(query, limit: limit)
}
```

**Toolset definitions:**

```swift
let toolsetDefinitions: [String: ToolsetDef] = [
    "web": .init(description: "Web research tools", tools: ["web_search", "web_extract"]),
    "terminal": .init(description: "Shell commands", tools: ["terminal", "process"]),
    "file": .init(description: "File manipulation", tools: ["read_file", "write_file", "patch"]),
    "delegation": .init(description: "Subagent spawning", tools: ["delegate_task"]),
    "kanban": .init(description: "Multi-agent board", tools: ["kanban_show", "kanban_complete", ...]),
    // ... 20+ more
]
```

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

**Key differences from Hermes:**
- No runtime discovery (no AST scanning, no importlib). Tools are registered at compile time.
- Plugin tools register via a different mechanism (`.dylib` bundles or a plugin directory scanned at startup).
- The check_fn TTL cache is replaced by Swift's actor-based caching with the same transient-failure grace window.

---

### 3. Provider System

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

Providers are registered in three tiers:
1. **Bundled** — compiled into the binary (OpenAI, Anthropic, OpenRouter, DeepSeek, Google, xAI, MiniMax, etc.)
2. **User plugins** — `.dylib` bundles in `~/.arc/plugins/model-providers/`
3. **Config-defined** — custom endpoints defined in `config.yaml` with base URL + provider template

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

**Credential pooling:**

```swift
actor CredentialPool {
    struct Entry {
        let apiKey: String
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

### 4. Session Management

ARC Agent uses **LMDB** via **QuickLMDB** for all persistent storage. Instead of a relational database with tables, joins, and a query planner, each subsystem gets its own LMDB environment (`.mdb` file) containing typed key-value databases. The key structure encodes the access pattern — the B-tree cursor IS the query plan.

**Environments:**

```
~/.arc/
├── arc-sessions.mdb     # Session metadata + messages + full-text index
├── arc-kanban.mdb       # Kanban board tasks, dependencies, comments
└── arc-config.mdb       # Config, memory, cron jobs, credentials
```

**Why LMDB over a relational store:**

- **Zero-copy reads** — readers get a direct pointer into the memory-mapped file. A session lookup is a single B-tree walk, then a pointer return. No result-set materialization, no copying.
- **No query planner** — the key structure IS the query plan. Every access pattern is known at compile time. No `EXPLAIN ANALYZE`, no index selection, no table-scan surprises.
- **No schema migrations** — adding a new index is creating a new named database. Old data stays untouched. No `ALTER TABLE` locking a production database.
- **Reader-writer concurrency** — unlimited concurrent readers with zero locking. Writers never block readers. Maps perfectly to the gateway model (many concurrent sessions reading, one cron tick writing).
- **Single file per environment** — backup is `cp` the `.mdb` file. No dump/restore, no VACUUM, no WAL checkpointing.
- **Compile-time type safety** — `Database.Strict<K,V>` catches key/value type mismatches at build time. A `Strict<SessionID, SessionMeta>` database physically cannot store a kanban task.

**Environment layout:**

```
┌─────────────────────────────────────────────────────────────┐
│  arc-sessions.mdb                                           │
│  maxReaders: 64  |  maxDBs: 16  |  mapSize: dynamic        │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ sessions: Strict<SessionID, SessionMeta>              │   │
│  │ Key:   UUID (16 bytes, big-endian)                    │   │
│  │ Value: created_at + updated_at + model + provider     │   │
│  │        + message_count (fixed-size struct)            │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ messages: DupSort<SessionID, MessageHeader>           │   │
│  │ Key:   SessionID (UUID, 16 bytes)                     │   │
│  │ Value: role_byte + timestamp + body_len + body_offset │   │
│  │ Dup:   multiple messages per session, insertion order │   │
│  │ Scan:  cursor.set_range(sessionID) → iterate until    │   │
│  │        key no longer starts with that SessionID       │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ msg_bodies: Strict<MessageID, Body>                   │   │
│  │ Key:   hash(SessionID + sequence_number, 16 bytes)    │   │
│  │ Value: variable-length message text                   │   │
│  │ Note:  Bodies stored separately so header scans are   │   │
│  │        fast — no variable-length data in the dup sort │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ sessions_by_source: DupSort<SourceTag, SessionID>     │   │
│  │ Key:   "cli" | "telegram" | "api" | "discord" | ...  │   │
│  │ Value: SessionID (UUID, 16 bytes)                     │   │
│  │ Use:   list all Telegram sessions                     │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ word_index: DupSort<WordHash, MessageLoc>             │   │
│  │ Key:   blake2(word, 4 bytes)                          │   │
│  │ Value: (SessionID + sequence_number)                  │   │
│  │ Use:   full-text search via inverted index            │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

**Composite key patterns (inspired by pricedb2's DateUTCPairHash):**

```
SessionMessageKey = SessionID (16 bytes) + SequenceNumber (8 bytes BE)
  → All messages for a session are contiguous in B-tree order.
    cursor.set_range(SessionID) and iterate until the key prefix changes.

MessageBodyKey = blake2b(SessionID + seq_num, 16 bytes)
  → Direct lookup of a specific message body by content hash.

WordIndexKey = blake2b(word, 4 bytes)
  → 4-byte hash is small enough for fast B-tree comparison,
    large enough to keep collisions rare in practice.
```

**Key operations:**

- `createSession()` — generate UUID, put into `sessions` database
- `appendMessage()` — put header into `messages` (DupSort), put body into `msg_bodies`, update session metadata
- `getSessionMessages(id)` — `cursor.set_range(id)` on `messages`, iterate until key prefix changes, look up bodies from `msg_bodies`
- `searchSessions(query)` — tokenize query, look up each token in `word_index`, intersect result sets by MessageLoc
- `listSessionsBySource(source)` — `cursor.set(source)` on `sessions_by_source`, iterate all dup values

**Transaction pattern:**

```swift
// All reads are read-only transactions — zero contention with writers.
func getSessionMessages(id: SessionID) throws -> [Message] {
    let tx = try Transaction(env: sessionsEnv, readOnly: true)
    return try messages.cursor(tx: tx) { cursor in
        var results: [Message] = []
        var cursorKey = id.rawBytes  // prefix scan
        try cursor.setRange(key: cursorKey)
        while cursorKey.hasPrefix(id.rawBytes) {
            let header: MessageHeader = try cursor.value()
            let body: String = try msg_bodies.get(key: header.bodyKey, tx: tx)
            results.append(Message(header: header, body: body))
            try cursor.next()
        }
        return results
    }
    // Transaction auto-closes — no cleanup needed.
}
```
- `compressSession(id)` — create compressed summary, branch to new parent_session_id
- `exportSession(id)` — JSONL export

---

### 5. Gateway / Messaging

**Architecture:**

```
GatewayService (Swift Service Lifecycle)
├── HTTPServer (Hummingbird)
│   ├── POST /v1/chat          — API server endpoint
│   └── GET  /health           — health check
├── PlatformAdapters
│   ├── TelegramAdapter        — Bot API (long polling or webhook)
│   ├── DiscordAdapter         — Gateway websocket + REST
│   ├── SlackAdapter           — Socket mode or Events API
│   └── ... (one per platform)
├── AgentCache (actor)
│   └── LRU<SessionID, ArcAgent> with idle TTL eviction
└── Dispatcher
    ├── SessionRouter          — maps incoming messages to sessions
    └── DeliveryManager        — sends responses back to platforms
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

**Agent cache:**

```swift
actor AgentCache {
    private var cache: LRUCache<String, ArcAgent>
    private var idleTTL: Duration
    
    func getOrCreate(sessionID: String, factory: () async -> ArcAgent) async -> ArcAgent
    func evict(sessionID: String)
    func sweepIdle()             // periodic task
}
```

---

### 6. Security / Approval System

**Architecture:**

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
let dangerousPatterns: [NSRegularExpression] = [
    try! NSRegularExpression(pattern: "rm\\s+-rf"),
    try! NSRegularExpression(pattern: ">\\s*/dev/"),
    try! NSRegularExpression(pattern: "chmod\\s+777"),
    try! NSRegularExpression(pattern: ":(){ :\\|:& };:"),  // fork bomb
    // ... 50+ patterns
]

func detectDangerousCommand(_ command: String) -> DangerLevel? {
    for pattern in dangerousPatterns {
        if pattern.firstMatch(in: command) != nil {
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

### 7. Delegation System

**Architecture:**

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

### 8. Cron Scheduler

**Architecture:**

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

### 9. Kanban Board

**Architecture:**

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

### 10. Memory System

**Architecture:**

```swift
protocol MemoryProvider: Sendable {
    func read() async throws -> String
    func append(_ text: String) async throws
    func replace(old: String, new: String) async throws
}

struct FileMemoryProvider: MemoryProvider {
    private let memoryPath: URL     // ~/.arc/memories/MEMORY.md
    private let userPath: URL       // ~/.arc/memories/USER.md
    
    func read() async throws -> String { ... }
    func append(_ text: String) async throws { ... }
    func replace(old: String, new: String) async throws { ... }
}
```

**Memory injection into system prompt:**

The memory manager reads both `MEMORY.md` and `USER.md` at session start and appends them to the system prompt. Memory is updated during post-turn hooks when the agent calls the `memory` tool.

---

### 11. Skills System

**Architecture:**

```swift
struct Skill: Sendable {
    let name: String
    let description: String
    let content: String             // full SKILL.md content
    let tags: [String]
    let category: String?
    let path: URL
}
```

**Skill discovery:**

```swift
func discoverSkills(in directory: URL) -> [Skill] {
    // Scan for SKILL.md files under ~/.arc/skills/
    // Parse YAML frontmatter
    // Return sorted by name
}
```

**Skills index in system prompt:**

The prompt builder reads all skill descriptions (first 57 chars) and formats them as a compact index that the agent scans before deciding to load a skill. Skills are loaded on demand via the `skill_view` tool.

---

### 12. Config System

**Architecture:**

```swift
struct ArcConfig: Codable, Sendable {
    var model: ModelConfig
    var agent: AgentConfig
    var terminal: TerminalConfig
    var delegation: DelegationConfig
    var memory: MemoryConfig
    var security: SecurityConfig
    var gateway: GatewayConfig?
    var cron: CronConfig?
    var kanban: KanbanConfig?
}

struct ModelConfig: Codable, Sendable {
    var defaultModel: String
    var provider: String
    var baseURL: String?
    var apiKey: String?          // read from .env, never stored in config.yaml
    var contextLength: Int?
}
```

**Resolution order:**
1. CLI flags (highest priority)
2. Environment variables
3. `config.yaml`
4. Compiled-in defaults (lowest priority)

**File layout:**

```
~/.arc/
├── config.yaml           # All settings
├── .env                  # Secrets only (API keys, tokens)
├── memories/
│   ├── MEMORY.md         # Agent's persistent notes
│   └── USER.md           # User profile
├── sessions/
│   └── arc-sessions.mdb  # LMDB session store
├── skills/               # Installed skills
├── logs/
├── cron/
├── plugins/
│   └── model-providers/  # Custom provider plugins
└── cache/
    └── delegation/live/  # Live subagent transcripts
```

---

### 13. CLI

**Architecture:**

```swift
// Swift Argument Parser entry point
@main
struct Arc: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "arc",
        subcommands: [
            Chat.self,
            Gateway.self,
            Config.self,
            Setup.self,
            Doctor.self,
            Sessions.self,
            Skills.self,
            Cron.self,
            Kanban.self,
            Profile.self,
        ]
    )
}

struct Chat: AsyncParsableCommand {
    @Option(name: .shortAndLong, help: "Single query, non-interactive")
    var query: String?
    
    @Option(name: .shortAndLong, help: "Model to use")
    var model: String?
    
    @Flag(name: .shortAndLong, help: "Verbose output")
    var verbose: Bool = false
    
    func run() async throws {
        let agent = try await ArcAgentBuilder.build(model: model)
        if let q = query {
            let response = try await agent.runConversation(message: q)
            print(response)
        } else {
            try await runInteractive(agent: agent)
        }
    }
}
```

**Interactive REPL (minimal, no TUI):**

A line-oriented REPL using Swift's `readLine()` with ANSI escape codes for basic formatting. Supports slash commands (`/model`, `/retry`, `/compress`, `/help`). No prompt_toolkit equivalent — this is intentionally minimal.

---

### 14. Interactive TUI (Optional)

If built, would use:
- **Swift-ncurses** or a custom ANSI terminal framework
- Split-pane layout: conversation history + tool progress + input line
- Real-time streaming display
- `/agents` overlay for delegation tree

This is the lowest priority subsystem. The CLI REPL + gateway cover 95% of use cases.

---

## Technology Stack

| Layer | Technology | Rationale |
|---|---|---|
| Language | Swift 6+ | Strict concurrency checking, actor isolation, Sendable |
| HTTP server | Hummingbird | Lightweight, Swift-native, async/await |
| HTTP client | AsyncHTTPClient | NIO-based, streaming support |
| Storage | QuickLMDB (LMDB) | Memory-mapped, zero-copy reads, no query planner |
| YAML | Yams | Pure Swift, well-maintained |
| JSON | Foundation `Codable` | Built-in, fast, type-safe |
| Argument parsing | Swift Argument Parser | Declarative, compile-time safe |
| Lifecycle | Swift Service Lifecycle | Tree of services, graceful shutdown |
| Cron parsing | Custom or swift-cron | Simple expression parser |
| Regex | Swift Regex (2023+) | Built-in, type-safe |
| Crypto | `CryptoKit` | Built-in, hardware-accelerated |
| Terminal UI | Swift-ncurses (optional) | Only if TUI is built |

---

## Build Order & Milestones

### Phase 1: Core Agent (Days 1-2 at 200M tokens/day)

- [ ] Project scaffold: Swift Package Manager, module structure, config loading
- [ ] Tool registry with compile-time registration
- [ ] 5 core tools: `terminal`, `read_file`, `write_file`, `web_search`, `web_extract`
- [ ] OpenAI-compatible API client (single provider: OpenRouter)
- [ ] Agent loop: build prompt → call LLM → dispatch tools → repeat
- [ ] Basic CLI: `arc chat -q "hello"`
- [ ] Session store (LMDB, basic CRUD)

**Deliverable:** A working agent that can chat, run shell commands, read/write files, and search the web. Single binary, instant startup.

### Phase 2: Production Readiness (Days 3-4)

- [ ] Provider system: 10+ provider profiles, credential pooling
- [ ] Security/approval system with three modes
- [ ] Memory system (built-in file-based)
- [ ] Skills system (discovery, loading, index in prompt)
- [ ] Context compression
- [ ] Error handling: rate limits, fallback models, retry logic
- [ ] Interactive REPL with slash commands
- [ ] Config wizard (`arc setup`)

**Deliverable:** A daily-driver agent that remembers across sessions, loads skills, handles API errors gracefully, and protects against dangerous commands.

### Phase 3: Multi-Agent (Days 5-7)

- [ ] Delegation system with toolset intersection
- [ ] Steering (list, steer, stop children)
- [ ] Kanban board with LMDB backend
- [ ] Kanban dispatcher (background service)
- [ ] Cron scheduler with job store
- [ ] Monitor mode for cron jobs

**Deliverable:** Multi-agent orchestration with subagent delegation, kanban workflow, and scheduled jobs.

### Phase 4: Gateway (Days 8-12)

- [ ] Hummingbird HTTP server
- [ ] API server platform adapter
- [ ] Telegram platform adapter
- [ ] Agent cache with LRU + idle TTL
- [ ] Session routing and delivery
- [ ] Progress display for gateway sessions

**Deliverable:** Multi-platform agent that runs as a daemon, serving API requests and Telegram messages.

### Phase 5: Polish (Days 13-15)

- [ ] Plugin system (`.dylib` bundles for providers + tools)
- [ ] MCP server support
- [ ] Additional platform adapters (Discord, Slack, WhatsApp)
- [ ] Performance optimization
- [ ] Documentation
- [ ] Distribution (Homebrew formula, Docker image)

**Deliverable:** Feature-complete agent framework ready for public use.

---

## Key Architectural Decisions (Unresolved)

These need design work before implementation begins:

### 1. Plugin system design

Swift has no equivalent of Python's `importlib`. Options:
- **Compile-time registration**: All plugins are bundled in the binary. Simple but not extensible.
- **dlopen bundles**: `.dylib` files implementing a known protocol. Flexible but complex.
- **Subprocess plugins**: Plugins run as separate processes communicating via JSON-RPC over stdin/stdout (like MCP). Simple, isolated, but higher latency.
- **Recommendation**: Start with compile-time registration for built-in tools/providers, add MCP-style subprocess plugins for extensibility.

### 2. Browser automation

Hermes uses Playwright (Node.js). Options for ARC:
- **Native CDP client**: Implement Chrome DevTools Protocol directly via WebSocket. Feasible but significant work.
- **Shell to headless browser**: Use `xcrun` or a system-installed Chromium with CDP flags. Simple but requires external binary.
- **Skip browser tools**: Browser automation is a nice-to-have, not core.
- **Recommendation**: Skip for v1. Add native CDP client as a later phase.

### 3. Interactive TUI

- **Option A**: Minimal REPL with `readLine()` + ANSI codes. Works, looks basic.
- **Option B**: Swift-ncurses with split-pane layout. More work, better UX.
- **Option C**: Skip entirely, focus on CLI + gateway.
- **Recommendation**: Start with Option A (minimal REPL). Add Option B only if there's clear demand.

### 4. Provider API surface

Each provider has subtle API differences. The OpenAI-compatible format covers ~95% of providers. The remaining 5% (Anthropic Messages API, Google Gemini, MiniMax) need separate client implementations. Decision: support OpenAI-compatible + Anthropic Messages API for v1, add others based on demand.

### 5. Storage format

ARC Agent uses LMDB via QuickLMDB for all persistent storage. Each subsystem gets its own `.mdb` environment with typed key-value databases. The key structure encodes the access pattern — no query planner, no schema migrations, no relational store. The schema IS the set of named databases and their key/value types. See the Session Management section above for the full environment layout.

The key design choices, inspired by pricedb2's proven schema:
- **Fixed-size binary keys** with big-endian byte ordering for correct B-tree sorting
- **Composite keys** that encode relationships directly in the key space (e.g. `SessionID + SequenceNumber` for messages)
- **Duplicate sort databases** for one-to-many and many-to-many relationships (messages per session, tasks by status)
- **Separate environments** for independent domains (sessions, kanban, config) — each with its own `mapSize`, `maxReaders`, and `maxDBs`
- **Append-friendly key design** for time-series data (cron ticks, session creation dates)

### 6. Native web UI

A web-based user interface is a non-negotiable requirement for the 1.0 release. The author will not write JavaScript, CSS, or HTML by hand. Options:

- **Swift-to-WASM compilation**: Compile the Swift agent to WebAssembly and serve it as a client-side app. Experimental but aligns with the Swift-native ethos.
- **Swift web frameworks**: Use a server-side Swift web framework (Hummingbird is already a dependency) to render HTML server-side with HTMX for interactivity. No JavaScript required beyond what HTMX provides.
- **Tauri-style native + web**: Bundle a web view with a native Swift backend, using the web view purely as a rendering surface. The UI logic stays in Swift.
- **Delegated to a separate project**: The web UI is built by a different toolchain (or a different person) and communicates with the agent via its HTTP API.

- **Recommendation**: Deferred. The gateway HTTP API (Phase 4) is the prerequisite — once the agent exposes a REST API, any web UI can consume it. The web UI itself is not designed until the API surface is stable.

---

## Cost Estimate (200M tokens/day)

| Phase | Est. Tokens | Est. Time | Est. Cost (at $0.50/M tok) |
|---|---|---|---|
| Phase 1: Core Agent | 15-25M | 2-3 hours | $7.50-$12.50 |
| Phase 2: Production Readiness | 20-30M | 2-3 hours | $10-$15 |
| Phase 3: Multi-Agent | 25-40M | 3-4 hours | $12.50-$20 |
| Phase 4: Gateway | 30-50M | 4-6 hours | $15-$25 |
| Phase 5: Polish | 20-30M | 2-3 hours | $10-$15 |
| **Total** | **110-175M** | **13-19 hours** | **$55-$87.50** |

These are generation-only estimates. Real-world costs include debugging iterations, design exploration, and testing — realistically **2-3x** the generation estimate, or **$150-$250** total for a complete v1.

---

## Comparison: ARC vs Hermes

| Dimension | Hermes (Python) | ARC (Swift) |
|---|---|---|
| Startup time | ~500ms-2s | <50ms |
| Memory footprint | ~150-300MB | ~20-50MB |
| Distribution | pip + venv + 227MB repo | Single binary (~20MB) |
| Dependencies | 100+ Python packages + npm | 10-15 Swift packages |
| Concurrency | threading + asyncio hybrid | Structured async/await + actors |
| Type safety | Runtime (duck typing) | Compile-time (strong typing) |
| Plugin system | Dynamic import (any .py file) | dlopen bundles or MCP subprocess |
| Tool schema gen | Dicts at runtime | Codable + macros at compile time |
| Browser automation | Playwright (Node.js) | Native CDP or skip |
| TUI | prompt_toolkit (rich) | Minimal REPL or ncurses |
| Platform support | Linux, macOS, Windows | Linux, macOS (Windows via Swift) |
| Maturity | Battle-tested, 231k stars | Greenfield |

---

## Conclusion

ARC Agent is an ambitious but achievable project. The architecture is well-understood (Hermes proves the concept at scale), the technology stack is well-suited (Swift's concurrency model is arguably better for this use case than Python's), and the automated development budget is sufficient to build a working v1 in under 20 hours of generation time.

The key risks are:
1. **Plugin system** — Swift's lack of dynamic loading makes extensibility harder
2. **Browser automation** — No good Swift-native equivalent to Playwright
3. **TUI** — No Swift equivalent to prompt_toolkit
4. **Scope creep** — Hermes is 126K+ lines across 15 subsystems. Staying focused on the core is essential

The key advantages are:
1. **Single binary distribution** — `brew install arc` and done
2. **Instant startup** — No interpreter overhead
3. **Type safety** — Compile-time guarantees for tool schemas and config
4. **No npm** — Zero JavaScript dependency chain
5. **Swift ecosystem** — Swift Argument Parser, Swift Service Lifecycle, QuickLMDB, Hummingbird

---

*This vision document is a living artifact. As development proceeds, each subsystem will get its own detailed design document under `docs/`. The architecture described here is the target — pragmatic deviations during implementation are expected and welcome.*
