import Foundation
import AsyncHTTPClient
import NIOCore
import NIOHTTP1
import CryptoKit

// MARK: - Event Hooks (reference `website/docs/user-guide/features/hooks.md`)

/// A hook context value. Handlers receive typed values (JSON round-trips to
/// the reference shape: arrays, booleans, integers, strings).
public enum HookValue: Sendable, Equatable, Codable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case array([String])

    public var stringValue: String {
        switch self {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .array(let a): return a.joined(separator: ",")
        }
    }
}

/// Event context passed to handlers (reference `context` dict).
public struct HookContext: Sendable {
    public let values: [String: HookValue]
    public init(_ values: [String: HookValue] = [:]) { self.values = values }

    public func string(_ key: String) -> String? {
        values[key]?.stringValue
    }
    public func bool(_ key: String) -> Bool? {
        if case .bool(let b) = values[key] { return b }
        return values[key].flatMap { $0.stringValue == "true" ? true : nil }
    }
    public func int(_ key: String) -> Int? {
        if case .int(let i) = values[key] { return i }
        return values[key].flatMap { Int($0.stringValue) }
    }
    public func array(_ key: String) -> [String]? {
        if case .array(let a) = values[key] { return a }
        return nil
    }
}

/// A hook handler: receives (event, context). Fire-and-forget observers.
public typealias HookHandler = @Sendable (String, HookContext) async -> Void

/// A blocking hook decision (reference `pre_tool_call` / `pre_llm_call`).
public enum HookDecision: Sendable, Equatable {
    /// Veto the tool call; the message becomes the error returned to the model.
    case block(message: String)
    /// Prepended context (pre_llm_call only).
    case context(String)
}

/// A hook that can steer the agent (plugin hooks with return values).
public typealias BlockingHookHandler = @Sendable (String, HookContext) async -> HookDecision?

/// One file-backed gateway hook (HOOK.yaml + handler script under
/// `~/.arc/hooks/<name>/`).
public struct FileHook: Sendable {
    public let name: String
    public let description: String
    public let events: [String]
    public let handlerURL: URL
    /// The interpreter to run (e.g. `python3` for handler.py). nil = execute
    /// the file directly.
    public let interpreter: String?

    /// Match `event` against declared events (exact or `command:*` wildcard).
    public func matches(_ event: String) -> Bool {
        for declared in events {
            if declared == event { return true }
            if declared.hasSuffix(":*"), event.hasPrefix(declared.dropLast(1)) { return true }
        }
        return false
    }
}

/// Central hook bus (reference `HookRegistry` + `hooks.emit()`).
///
/// All emits are non-blocking: events are serialized through a bounded queue
/// and handled by a single background consumer. Handler errors are caught and
/// logged — a broken hook never crashes the agent.
public actor HookBus {

    public static let shared = HookBus()

    /// Programmatic handlers (plugin hooks). Loaded per process.
    private var handlers: [(events: [String], handler: HookHandler)] = []

    /// Blocking handlers (pre_tool_call, pre_llm_call, pre_verify).
    private var blockingHandlers: [(event: String, handler: BlockingHookHandler)] = []

    /// File-backed gateway hooks — loaded explicitly by the gateway entry
    /// (reference: CLI does not load gateway hooks).
    private var fileHooks: [FileHook] = []

    /// Outbound webhook targets (reference `hooks.outbound`).
    private var outbound: [OutboundWebhookTarget] = []
    private var httpClient: HTTPClient?
    private var ownedClient: HTTPClient?

    deinit {
        try? ownedClient?.syncShutdown()
    }

    // Bounded job queue + consumer (serialized, non-blocking emit).
    private var continuation: AsyncStream<HookJob>.Continuation?
    private var consumerStarted = false
    private let queueCapacity = 256

    private struct HookJob: Sendable {
        let event: String
        let context: HookContext
    }

    public init() {}
    private func ensureConsumer() {
        guard !consumerStarted else { return }
        consumerStarted = true
        var stream: AsyncStream<HookJob>!
        let capacity = queueCapacity
        let (s, cont) = AsyncStream.makeStream(of: HookJob.self, bufferingPolicy: .bufferingNewest(capacity))
        stream = s
        continuation = cont
        let bus = self
        let task = Task { [bus] in
            for await job in stream {
                await bus.consume(job)
                if Task.isCancelled { break }
            }
        }
        _ = task
    }

    // MARK: - Registration

    /// Register a programmatic handler (plugin hooks: tool interception,
    /// metrics, guardrails — fire where the CLI AND gateway run).
    public func register(events: [String], handler: @escaping HookHandler) {
        handlers.append((events, handler))
    }

    /// Register a blocking handler (reference `ctx.register_hook` for
    /// pre_tool_call/pre_llm_call/pre_verify). First non-nil decision wins.
    public func registerBlocking(_ event: String, handler: @escaping BlockingHookHandler) {
        blockingHandlers.append((event, handler))
    }

    /// Query blocking handlers synchronously (called on the hot path — the
    /// agent awaits the decision before proceeding).
    public func queryBlocking(_ event: String, _ context: [String: HookValue] = [:]) async -> HookDecision? {
        for (registered, handler) in blockingHandlers where registered == event {
            do {
                if let decision = await handler(event, HookContext(context)) {
                    return decision
                }
            } catch {
                LoggerHolder.log("blocking hook \(event) error: \(error)")
            }
        }
        return nil
    }

    /// Load file-backed gateway hooks from `~/.arc/hooks/` (reference
    /// `HookRegistry.discover_and_load()`). Handlers are `handler.py`
    /// (executed by `python3`) — same `handle(event, context)` contract.
    public func loadFileHooks(directory: URL? = nil) async {
        let base = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arc/hooks")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory)
            guard isDirectory.boolValue else { continue }
            let yamlURL = entry.appendingPathComponent("HOOK.yaml")
            guard let manifest = try? String(contentsOf: yamlURL, encoding: .utf8) else { continue }
            guard let parsed = HookYAMLParser.parse(manifest) else { continue }

            let handlerURL = entry.appendingPathComponent("handler.py")
            let interpreter: String? = FileManager.default.fileExists(atPath: handlerURL.path) ? "python3" : nil
            let anyHandler: URL? = interpreter == nil ? entry.appendingPathComponent("handler") : handlerURL
            guard let handlerURL2 = anyHandler ?? (FileManager.default.fileExists(atPath: entry.appendingPathComponent("handler").path) ? entry.appendingPathComponent("handler") : nil) else { continue }

            fileHooks.append(FileHook(
                name: parsed.name, description: parsed.description,
                events: parsed.events, handlerURL: handlerURL2,
                interpreter: interpreter
            ))
        }
    }

    // MARK: - Configuration (outbound)

    public func fileHookSummaries() -> [FileHook] {
        fileHooks
    }

    /// Configure outbound webhook targets (reference `hooks.outbound`).
    public func configureOutbound(_ targets: [OutboundWebhookTarget], httpClient: HTTPClient? = nil) {
        outbound = targets
        self.httpClient = httpClient
    }

    // MARK: - Emit

    /// Fire an event (non-blocking). Matches file hooks, programmatic
    /// handlers, and outbound targets.
    public func emit(_ event: String, _ context: [String: HookValue] = [:]) {
        ensureConsumer()
        let job = HookJob(event: event, context: HookContext(context))
        continuation?.yield(job)
    }

    private func consume(_ job: HookJob) async {
        // 1. Programmatic handlers (plugin hooks).
        for (events, handler) in handlers where matchesAny(events, job.event) {
            do {
                await handler(job.event, job.context)
            } catch {
                LoggerHolder.log("hook \(job.event): handler error: \(error)")
            }
        }
        // 2. File-backed gateway hooks.
        for hook in fileHooks where hook.matches(job.event) {
            await runFileHook(hook, job)
        }
        // 3. Outbound webhooks (signed, retry-once).
        for target in outbound where target.matches(job.event) {
            await deliverOutbound(target, job)
        }
    }

    private func matchesAny(_ declared: [String], _ event: String) -> Bool {
        for d in declared {
            if d == event { return true }
            if d.hasSuffix(":*"), event.hasPrefix(d.dropLast(1)) { return true }
        }
        return false
    }

    // MARK: - File handler execution

    private func runFileHook(_ hook: FileHook, _ job: HookJob) async {
        do {
            let process = Process()
            if let interpreter = hook.interpreter {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [interpreter, hook.handlerURL.path, job.event]
            } else {
                process.executableURL = hook.handlerURL
                process.arguments = [job.event]
            }
            let input = Pipe()
            let output = Pipe()
            let errorPipe = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errorPipe

            try process.run()
            let body = try JSONSerialization.data(withJSONObject: hookJSONPayload(job), options: [])
            input.fileHandleForWriting.write(body)
            try? input.fileHandleForWriting.close()

            // Bounded wait: 30 s cap, then kill.
            let deadline = Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if process.isRunning { process.terminate() }
            }
            _ = try? await process.waitUntilExit()
            deadline.cancel()

            let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if process.terminationStatus != 0, !stderr.isEmpty {
                LoggerHolder.log("hook \(hook.name): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        } catch {
            LoggerHolder.log("hook \(hook.name) failed: \(error)")
        }
    }

    private func hookJSONPayload(_ job: HookJob) -> [String: Any] {
        var dict: [String: Any] = [:]
        for (key, value) in job.context.values {
            switch value {
            case .string(let s): dict[key] = s
            case .bool(let b): dict[key] = b
            case .int(let i): dict[key] = i
            case .array(let a): dict[key] = a
            }
        }
        return dict
    }

    // MARK: - Outbound delivery

    private func deliverOutbound(_ target: OutboundWebhookTarget, _ job: HookJob) async {
        let httpClient = self.httpClient ?? createOwnedClientIfNeeded()
        guard let httpClient else { return }
        let deliveryID = UUID().uuidString
        let payload: [String: Any] = [
            "hook_event_name": job.event,
            "tool_name": job.context.string("tool_name") ?? NSNull(),
            "tool_input": job.context.string("tool_input") ?? NSNull(),
            "session_id": job.context.string("session_id") ?? NSNull(),
            "cwd": job.context.string("cwd") ?? FileManager.default.currentDirectoryPath,
            "extra": extraPayload(job.context),
            "delivery_id": deliveryID,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
        let secret = target.resolvedSecret()
        var headers: HTTPHeaders = [
            "Content-Type": "application/json",
            "User-Agent": "Arc-Agent-Outbound-Webhook",
            "X-Hermes-Event": job.event,
            "X-Hermes-Delivery": deliveryID,
        ]
        if let secret, !secret.isEmpty {
            let signature = "sha256=" + HMACSHA256.hexDigest(key: secret, data: body)
            headers.add(name: "X-Hermes-Signature-256", value: signature)
        }
        let request = try? HTTPClient.Request(
            url: target.url,
            method: .POST,
            headers: headers,
            body: .byteBuffer(ByteBuffer(bytes: body))
        )
        guard let request else { return }
        // Retry once on transport/5xx (reference delivery semantics). 3xx is
        // never followed; 4xx is not retried.
        for attempt in 0...1 {
            do {
                let timeout = TimeAmount.seconds(Int64(target.timeout(clamped: 60)))
                let deadline = NIODeadline.now() + timeout
                let response = try await httpClient.execute(request: request, deadline: deadline).get()
                let status = response.status.code
                if (200..<300).contains(status) { return }
                if (300..<400).contains(status) {
                    LoggerHolder.log("outbound \(target.name): 3xx redirect, not following (status \(status))")
                    return
                }
                if status >= 500, attempt == 0 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                return
            } catch {
                if attempt == 0 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                LoggerHolder.log("outbound \(target.name): \(error)")
            }
        }
    }

    private func createOwnedClientIfNeeded() -> HTTPClient? {
        if let ownedClient { return ownedClient }
        let client = HTTPClient(eventLoopGroupProvider: .singleton)
        ownedClient = client
        return client
    }

    private func extraPayload(_ context: HookContext) -> [String: Any] {
        var extra: [String: Any] = [:]
        for (key, value) in context.values where key != "tool_name" && key != "tool_input" && key != "session_id" && key != "cwd" {
            switch value {
            case .string(let s): extra[key] = s
            case .bool(let b): extra[key] = b
            case .int(let i): extra[key] = i
            case .array(let a): extra[key] = a
            }
        }
        return extra
    }
}

// MARK: - Outbound target (reference `hooks.outbound`)

public struct OutboundWebhookTarget: Sendable, Codable, Equatable {
    public var name: String?
    public var url: String
    public var events: [String]
    public var secret: String?
    public var secretEnv: String?
    public var timeout: Int?
    public var matcher: String?

    public init(name: String? = nil, url: String, events: [String], secret: String? = nil,
                secretEnv: String? = nil, timeout: Int? = nil, matcher: String? = nil) {
        self.name = name
        self.url = url
        self.events = events
        self.secret = secret
        self.secretEnv = secretEnv
        self.timeout = timeout
        self.matcher = matcher
    }

    enum CodingKeys: String, CodingKey {
        case name, url, events, secret, timeout, matcher
        case secretEnv = "secret_env"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        url = try c.decode(String.self, forKey: .url)
        events = try c.decode([String].self, forKey: .events)
        secret = try c.decodeIfPresent(String.self, forKey: .secret)
        secretEnv = try c.decodeIfPresent(String.self, forKey: .secretEnv)
        timeout = try c.decodeIfPresent(Int.self, forKey: .timeout)
        matcher = try c.decodeIfPresent(String.self, forKey: .matcher)
    }

    /// `secret_env` (preferred) > inline `secret`.
    public func resolvedSecret() -> String? {
        if let env = secretEnv, !env.isEmpty {
            return ProcessInfo.processInfo.environment[env]
        }
        return secret
    }

    /// Event subscription (matcher is applied to tool-scoped events at
    /// delivery time — see ``matches(event:context:)``).
    public func matches(_ event: String) -> Bool {
        events.contains(event)
    }

    /// Full matching incl. the optional tool-name matcher (regex over
    /// `tool_name`, honored for pre/post_tool_call only — reference).
    public func matches(event: String, context: HookContext) -> Bool {
        guard events.contains(event) else { return false }
        guard let matcher, !matcher.isEmpty,
              event == "post_tool_call" || event == "pre_tool_call" else { return true }
        guard (try? NSRegularExpression(pattern: matcher)) != nil else { return true }
        let toolName = context.string("tool_name") ?? ""
        return toolName.range(of: matcher, options: .regularExpression) != nil
    }

    public func timeout(clamped: Int) -> Int {
        max(1, min(timeout ?? 10, 60))
    }
}

// MARK: - Tiny HOOK.yaml parser (name/description/events)

enum HookYAMLParser {
    struct Manifest {
        let name: String
        let description: String
        let events: [String]
    }

    static func parse(_ text: String) -> Manifest? {
        var name = ""
        var description = ""
        var events: [String] = []
        var inEvents = false
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("events:") {
                inEvents = true
                let rest = line.dropFirst("events:".count).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("[") {
                    // inline list [a, b]
                    events = rest.dropFirst().dropLast().split(separator: ",")
                        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '[]\"")) }
                        .filter { !$0.isEmpty }
                    inEvents = false
                }
                continue
            }
            if inEvents, line.hasPrefix("-") {
                events.append(line.dropFirst().trimmingCharacters(in: CharacterSet(charactersIn: " '\"")))
                continue
            }
            if line.hasPrefix("name:"), name.isEmpty {
                name = line.dropFirst("name:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("description:"), !inEvents {
                description = line.dropFirst("description:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        guard !name.isEmpty, !events.isEmpty else { return nil }
        return Manifest(name: name, description: description, events: events)
    }
}

// MARK: - HMAC (GitHub-style sha256)

enum HMACSHA256 {
    static func hexDigest(key: String, data: Data) -> String {
        let keyBytes = SymmetricKey(data: Data(key.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: data, using: keyBytes)
        return signature.map { String(format: "%02x", $0) }.joined()
    }
}

/// Minimal logging seam so hooks never depend on a logger at compile time.
enum LoggerHolder {
    static func log(_ message: String) {
        let line = "[hooks] \(message)\n"
        FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
    }
}
