import ArcAgentCore
import ArcSidebarTabs
import Foundation
import Logging

// MARK: - Sidecar plugin client (host side)
//
// The host half of the sidecar protocol: a `SidebarTabPlugin`/`SidebarTab`
// facade over a plugin PROCESS. The application code (AppState, settings
// page, rail) keeps working unchanged — it sees ordinary kit protocol
// objects; the process boundary is the only difference vs. an in-process
// plugin.
//
// `SidecarConnection` is an actor owning the child session, the pending-RPC
// map and the reader tasks. Incoming lines are delivered by the session's byte
// pumps — no `readabilityHandler`, no Foundation I/O queue, and no child joining
// arc's own process group (the old `Process` form did exactly that, so a
// sidecar's own children were unreachable at teardown).

// MARK: - Connection

/// One sidecar plugin process, speaking the JSON-line RPC protocol.
public actor SidecarConnection {

    /// Host-side handlers for the plugin→host requests
    /// (`host.workspacePath`, `host.toast`, `host.navigate`, …).
    public typealias HostHandler = @Sendable (String, SidecarValue?) async throws -> SidecarValue

    private var session: SubprocessSession?
    private var readers: [Task<Void, Never>] = []
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<SidecarValue, Error>] = [:]
    private let binary: String
    private let hostHandler: HostHandler
    private let logger: Logger

    enum SidecarConnectionError: Error, CustomStringConvertible {
        case notExecutable(String)
        case processExited(Int32)

        var description: String {
            switch self {
            case .notExecutable(let p): return "sidecar binary is not executable: \(p)"
            case .processExited(let code): return "sidecar process exited with code \(code)"
            }
        }
    }

    public init(binary: String, hostHandler: @escaping HostHandler, logger: Logger? = nil) {
        self.binary = binary
        self.hostHandler = hostHandler
        self.logger = logger ?? Logger(label: "arc-agent.sidecar-plugins")
    }

    /// Spawn the plugin process and attach the channel readers.
    public func connect() async throws {
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw SidecarConnectionError.notExecutable(binary)
        }
        // The same session type every other long-lived child arc owns: `.own`
        // placement, byte channels, one reap task.
        let session = SubprocessSession(executable: binary)
        self.session = session
        let pid = try await session.start()
        startReaders(session)
        logger.info("sidecar plugin started: \(binary) (pid \(pid.map { String($0) } ?? "unknown"))")
    }

    /// Attach the three readers: plugin output, plugin stderr, and the exit
    /// watcher that fails in-flight calls instead of leaving them suspended.
    private func startReaders(_ session: SubprocessSession) {
        // JSON-lines protocol. One accumulator per stream, fed by the session's
        // byte pump — the same framing the old `readabilityHandler` fed.
        let outAccumulator = SidecarLineAccumulator { [weak self] line in
            Task { await self?.handle(line: line) }
        }
        let errAccumulator = SidecarLineAccumulator { [weak self] line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            Task { await self?.logStderr(trimmed) }
        }
        readers = [
            Task { for await bytes in session.stdout { outAccumulator.feed(Data(bytes)) } },
            Task { for await bytes in session.stderr { errAccumulator.feed(Data(bytes)) } },
            Task { [weak self] in
                let code = await session.waitForExit()
                await self?.processExited(Int32(code ?? -1))
            },
        ]
    }

    private func logStderr(_ line: String) {
        logger.info("sidecar[\(binary)]: \(line)")
    }

    /// Host→plugin RPC. `params` may be nil.
    public func call(_ method: String, params: SidecarValue? = nil) async throws -> SidecarValue {
        guard let session, await session.isRunning() else {
            throw SidecarConnectionError.processExited(-1)
        }
        nextID += 1
        let id = nextID
        let env = SidecarEnvelope.request(id: id, method: method, params: params)
        do {
            try await session.write(encodeLine(env))
        } catch {
            throw SidecarConnectionError.processExited(-1)
        }
        // The continuation is registered *after* the frame is flushed, and that
        // ordering is safe: `write` returning resumes this task and it runs
        // atomically up to the next suspension, while the reply handler needs this
        // actor — so a reply that arrives instantly is queued behind us, never
        // dropped for want of a pending id.
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
        }
    }

    /// Tear the process down. Idempotent.
    public func disconnect() async {
        if let session { await session.shutdown() }
        session = nil
        for reader in readers { await reader.value }
        readers = []
        for (_, cont) in pending {
            cont.resume(throwing: SidecarConnectionError.processExited(-1))
        }
        pending.removeAll()
    }

    /// True while a session is attached. Liveness itself is the exit watcher's
    /// job — it is what fails pending calls when the child goes away.
    public var isRunning: Bool { session != nil }

    // MARK: Reader

    private func processExited(_ code: Int32) {
        logger.warning("sidecar plugin exited (code \(code)): \(binary)")
        session = nil
        for (_, cont) in pending {
            cont.resume(throwing: SidecarConnectionError.processExited(code))
        }
        pending.removeAll()
    }

    private func handle(line: String) async {
        guard let data = line.data(using: .utf8),
              let env = try? JSONDecoder().decode(SidecarEnvelope.self, from: data)
        else { return }

        if let method = env.method, let id = env.id {
            // Plugin→host request: run the handler on its own task so a
            // plugin handler awaiting this cannot stall the reader.
            let params = env.params
            let handler = hostHandler
            Task { [weak self] in
                guard let self else { return }
                let reply: SidecarEnvelope
                do {
                    let result = try await handler(method, params)
                    reply = .reply(id: id, result: result)
                } catch {
                    reply = .reply(id: id, error: SidecarError(code: -32603, message: String(describing: error)))
                }
                await self.write(reply)
            }
            return
        }

        // Host→plugin reply: correlate by id.
        if let id = env.id, let cont = pending.removeValue(forKey: id) {
            if let error = env.error {
                cont.resume(throwing: SidecarRPCError(error))
            } else {
                cont.resume(returning: env.result ?? .null)
            }
        }
    }

    private func write(_ env: SidecarEnvelope) async {
        guard let session else { return }
        try? await session.write(encodeLine(env))
    }

    private func encodeLine(_ env: SidecarEnvelope) -> [UInt8] {
        var line = (try? JSONEncoder().encode(env)) ?? Data()
        line.append(0x0A)
        return Array(line)
    }
}

// MARK: - Tab client

/// A `SidebarTab` backed by a sidecar process. `install` asks the sidecar
/// for its registrations, then forwards every host event over the wire.
public struct SidecarPluginTab: SidebarTab {
    public let descriptor: SidecarTabDescriptor
    let connection: SidecarConnection

    public init(descriptor: SidecarTabDescriptor, connection: SidecarConnection) {
        self.descriptor = descriptor
        self.connection = connection
    }

    public var id: String { descriptor.id }
    public var title: String { descriptor.title }
    public var tooltip: String { descriptor.tooltip }

    public var icon: SidebarTabIcon {
        switch descriptor.iconKind {
        case "custom": return .custom(name: descriptor.iconA, body: descriptor.iconB)
        case "emoji": return .emoji(descriptor.iconA)
        default: return .named(descriptor.iconA)
        }
    }

    public func panelHTML() async -> String {
        await render(region: "panel")
    }

    public func mainHTML() async -> String {
        await render(region: "main")
    }

    private func render(region: String) async -> String {
        guard case .string(let html)? = try? await connection.call(
            SidecarMethod.render,
            params: .obj(["tab": .string(id), "region": .string(region)])
        ) else { return "<div class=\"empty-hint\">Sidecar plugin unavailable.</div>" }
        return html
    }

    public func install(_ registration: SidebarTabRegistration) async {
        guard case .array(let regs)? = try? await connection.call(
            SidecarMethod.install,
            params: .obj(["tab": .string(id)])
        ) else { return }
        for reg in regs {
            guard let obj = reg.object,
                  let cid = obj["id"]?.string else { continue }
            let events = Set(obj["events"]?.array?.compactMap { $0.string } ?? ["click", "change", "submit", "input"])
            registration.on(cid, events: events) { kitEvent in
                let values = Dictionary(uniqueKeysWithValues: kitEvent.values.map { (key, value) in
                    (key, SidecarValue(value))
                })
                let params: SidecarValue = .obj([
                    "tab": .string(self.id),
                    "component": .string(cid),
                    // `.string`, deliberately: this is the plugin's own
                    // JSON-lines wire protocol, not arc's UI vocabulary. the
                    // event name is data crossing a process boundary, so it
                    // travels as the string a third-party plugin expects —
                    // do not "type" this into `HTMLEvent`.
                    "event": .string(kitEvent.event),
                    "values": .object(values),
                ])
                guard case .array(let frags)? = try? await self.connection.call(
                    SidecarMethod.dispatchEvent, params: params
                ) else { return [] }
                return frags.compactMap { frag in
                    guard let o = frag.object, let region = o["region"]?.string, let html = o["html"]?.string
                    else { return nil }
                    switch region {
                    case "panel": return .panel(html)
                    case "main": return .main(html)
                    default: return nil
                    }
                }
            }
        }
    }

    public func onActivate(_ host: SidebarTabHost) async {
        _ = try? await connection.call(SidecarMethod.activate, params: .obj(["tab": .string(id)]))
    }

    public func onDeactivate(_ host: SidebarTabHost) async {
        _ = try? await connection.call(SidecarMethod.deactivate, params: .obj(["tab": .string(id)]))
    }
}

// MARK: - Plugin client

/// A `SidebarTabPlugin` facade over an installed sidecar: the descriptor
/// the Settings → Sidebar plugins page shows comes from `manifest.json`,
/// and `tabs()` returns the wire-backed tab clients.
public struct SidecarPluginClient: SidebarTabPlugin {
    public let name: String
    public let version: String
    public let description: String
    let connection: SidecarConnection
    let tabsInfo: [SidecarTabDescriptor]

    public init(
        name: String,
        version: String,
        description: String,
        connection: SidecarConnection,
        tabs: [SidecarTabDescriptor]
    ) {
        self.name = name
        self.version = version
        self.description = description
        self.connection = connection
        self.tabsInfo = tabs
    }

    public func tabs() -> [any SidebarTab] {
        tabsInfo.map { SidecarPluginTab(descriptor: $0, connection: connection) }
    }
}
