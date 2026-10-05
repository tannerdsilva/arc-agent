import Foundation

// MARK: - SidecarServer (plugin side)
//
// Runs a `SidebarTabPlugin` as a separate process: reads JSON lines from
// stdin, answers host RPCs, and forwards plugin→host requests from
// `SidebarTabHost` usage (workspacePath/toast/navigate/refreshTab).
//
// A plugin package adds one executable target:
//
//     SidecarServer.run(plugin: MyTabPlugin())
//
// and ships the built binary + a manifest.json in
// `~/.arc/plugins/<name>/` — the host discovers it at startup.
//
// Concurrency: an actor endpoint owns the pending-request map and all
// writes; a `readabilityHandler` feeds lines into it (single-threaded
// per handle — the accepted Foundation I/O pattern, see
// `SidecarLineAccumulator`). Inbound requests are dispatched on their
// own Tasks so a handler awaiting a host round-trip cannot stall the
// reader.

/// RPC failure surfaced to the plugin author.
public struct SidecarRPCError: Error, CustomStringConvertible {
    public let code: Int
    public let message: String

    public init(_ error: SidecarError) {
        self.code = error.code
        self.message = error.message
    }

    public var description: String { "sidecar rpc error \(code): \(message)" }
}

// MARK: - Host side-channel proxy (plugin side)

/// `SidebarTabHost` implementation that forwards calls to the host over
/// the wire. Tabs receive this from `onActivate`/`onDeactivate`.
public struct SidecarHostProxy: SidebarTabHost {
    let endpoint: SidecarEndpoint

    public func workspacePath() async -> String {
        guard case .string(let path)? = try? await endpoint.request(
            method: SidecarMethod.hostWorkspacePath, params: nil
        ) else { return "" }
        return path
    }

    public func toast(_ message: String) async {
        _ = try? await endpoint.request(
            method: SidecarMethod.hostToast,
            params: .obj(["message": .string(message)])
        )
    }

    public func navigate(to tabID: String) async {
        _ = try? await endpoint.request(
            method: SidecarMethod.hostNavigate,
            params: .obj(["tab": .string(tabID)])
        )
    }

    public func refreshTab(_ tabID: String) async {
        _ = try? await endpoint.request(
            method: SidecarMethod.hostRefreshTab,
            params: .obj(["tab": .string(tabID)])
        )
    }
}

// MARK: - Registrar collector (plugin side)

/// Collects `SidebarTab.install` registrations so the sidecar can tell
/// the host which component ids/events exist and replay events into the
/// tab's handlers. Created per `install` call and used synchronously
/// inside that one call — @unchecked is confined to that, documented.
final class SidecarRegistrarCollector: SidebarTabRegistrar, @unchecked Sendable {
    struct Registration: Sendable {
        let id: String
        let events: Set<String>
        let handler: @Sendable (SidebarTabEvent) async -> [SidebarFragment]
    }

    var collected: [Registration] = []

    func register(
        id: String,
        events: Set<String>,
        handler: @escaping @Sendable (SidebarTabEvent) async -> [SidebarFragment]
    ) {
        collected.append(Registration(id: id, events: events, handler: handler))
    }
}

// MARK: - Endpoint

/// The plugin process's half of the wire: one actor serializing requests
/// out, responses in, and inbound RPC dispatch.
public actor SidecarEndpoint {

    struct Handler {
        let events: Set<String>
        let run: @Sendable (SidebarTabEvent) async -> [SidebarFragment]
    }

    private let plugin: any SidebarTabPlugin
    private var tabsById: [String: any SidebarTab] = [:]
    private var handlers: [String: Handler] = [:]
    private var pending: [Int: CheckedContinuation<SidecarValue, Error>] = [:]
    private var nextID = 0
    private let stdin: FileHandle
    private let stdout: FileHandle
    private var eofContinuation: CheckedContinuation<Void, Never>?

    enum SidecarServerError: Error, CustomStringConvertible {
        case unknownTab(String)
        case unknownRegion(String)
        case unknownEvent(String)
        case eof

        var description: String {
            switch self {
            case .unknownTab(let t): return "unknown tab '\(t)'"
            case .unknownRegion(let r): return "unknown region '\(r)'"
            case .unknownEvent(let e): return "no handler for component '\(e)'"
            case .eof: return "sidecar stdin closed"
            }
        }
    }

    public init(plugin: any SidebarTabPlugin) {
        self.plugin = plugin
        self.stdin = FileHandle.standardInput
        self.stdout = FileHandle.standardOutput
    }

    // MARK: RPC surface (plugin → host)

    /// Send a plugin→host request and await the host's reply.
    public func request(method: String, params: SidecarValue?) async throws -> SidecarValue {
        nextID += 1
        let id = nextID
        let env = SidecarEnvelope.request(id: id, method: method, params: params)
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            do {
                try stdout.write(contentsOf: encodeLine(env))
            } catch {
                pending.removeValue(forKey: id)
                cont.resume(throwing: error)
            }
        }
    }

    // MARK: Run

    /// Run the stdio loop until the host closes stdin (EOF), then return.
    public func run() async throws {
        for tab in plugin.tabs() {
            tabsById[tab.id] = tab
        }

        let accumulator = SidecarLineAccumulator { [weak self] line in
            Task { await self?.handle(line: line) }
        }
        stdin.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                Task { await self?.eof() }
                return
            }
            accumulator.feed(data)
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            eofContinuation = cont
        }
    }

    /// The host asks for the tab descriptors (discovery handshake).
    public func listDescriptors() async -> [SidecarTabDescriptor] {
        var out: [SidecarTabDescriptor] = []
        for (_, tab) in tabsById.sorted(by: { $0.key < $1.key }) {
            out.append(SidecarTabDescriptor.make(tab))
        }
        return out
    }

    // MARK: Inbound handling

    private func eof() {
        for (_, cont) in pending {
            cont.resume(throwing: SidecarServerError.eof)
        }
        pending.removeAll()
        if let cont = eofContinuation {
            eofContinuation = nil
            cont.resume()
        }
    }

    private func handle(line: String) async {
        guard let data = line.data(using: .utf8),
              let env = try? JSONDecoder().decode(SidecarEnvelope.self, from: data)
        else { return }

        if let method = env.method, let id = env.id {
            // Host→plugin request. Dispatch on its own task so a nested
            // host round-trip (a tab calling host.workspacePath while
            // rendering) cannot stall the reader.
            let params = env.params
            Task { [weak self] in
                guard let self else { return }
                let reply = await self.handleRequest(method: method, params: params)
                let envelope: SidecarEnvelope
                switch reply {
                case .ok(let value): envelope = .reply(id: id, result: value)
                case .fail(let error): envelope = .reply(id: id, error: error)
                }
                await self.write(envelope)
            }
            return
        }

        // Plugin→host reply: correlate by id.
        if let id = env.id, let cont = pending.removeValue(forKey: id) {
            if let error = env.error {
                cont.resume(throwing: SidecarRPCError(error))
            } else {
                cont.resume(returning: env.result ?? .null)
            }
        }
    }

    private enum Reply {
        case ok(SidecarValue)
        case fail(SidecarError)
    }

    private func handleRequest(method: String, params: SidecarValue?) async -> Reply {
        do {
            switch method {
            case SidecarMethod.listTabs:
                let descriptors = await listDescriptors()
                let tabValues = descriptors.map { desc -> SidecarValue in
                    .obj([
                        "id": .string(desc.id),
                        "title": .string(desc.title),
                        "tooltip": .string(desc.tooltip),
                        "iconKind": .string(desc.iconKind),
                        "iconA": .string(desc.iconA),
                        "iconB": .string(desc.iconB),
                    ])
                }
                return .ok(.array(tabValues))

            case SidecarMethod.install:
                let tab = try param(params, "tab")
                guard let t = tabsById[tab] else { throw SidecarServerError.unknownTab(tab) }
                let collector = SidecarRegistrarCollector()
                await t.install(SidebarTabRegistration(collector))
                let regs = collector.collected.map { reg -> SidecarValue in
                    .obj([
                        "id": .string(reg.id),
                        "events": .array(reg.events.sorted().map(SidecarValue.string)),
                    ])
                }
                // Handlers are replayed from dispatchEvent using the
                // collector's closure table.
                for reg in collector.collected {
                    handlers[reg.id] = Handler(events: reg.events, run: reg.handler)
                }
                return .ok(.array(regs))

            case SidecarMethod.render:
                let tab = try param(params, "tab")
                let region = try param(params, "region")
                guard let t = tabsById[tab] else { throw SidecarServerError.unknownTab(tab) }
                let html: String
                switch region {
                case "panel": html = await t.panelHTML()
                case "main": html = await t.mainHTML()
                default: throw SidecarServerError.unknownRegion(region)
                }
                return .ok(.string(html))

            case SidecarMethod.dispatchEvent:
                let componentID = try param(params, "component")
                let eventName = try param(params, "event")
                let valueStrings: [String: String] = params?.key("values")?.object?.mapValues { $0.string ?? "" } ?? [:]
                guard let handler = handlers[componentID] else {
                    throw SidecarServerError.unknownEvent(componentID)
                }
                guard handler.events.contains(eventName) else { return .ok(.null) }
                let kitEvent = SidebarTabEvent(
                    componentID: componentID,
                    event: eventName,
                    values: valueStrings
                )
                let fragments = await handler.run(kitEvent)
                let fragmentValues = fragments.compactMap { frag -> SidecarValue? in
                    switch frag {
                    case .panel(let html): return .obj(["region": .string("panel"), "html": .string(html)])
                    case .main(let html): return .obj(["region": .string("main"), "html": .string(html)])
                    case .none: return nil
                    }
                }
                return .ok(.array(fragmentValues))

            case SidecarMethod.activate:
                let host = SidecarHostProxy(endpoint: self)
                if let t = tabsById[try param(params, "tab")] {
                    await t.onActivate(host)
                }
                return .ok(.null)

            case SidecarMethod.deactivate:
                let host = SidecarHostProxy(endpoint: self)
                if let t = tabsById[try param(params, "tab")] {
                    await t.onDeactivate(host)
                }
                return .ok(.null)

            default:
                return .fail(SidecarError(code: -32601, message: "method not found: \(method)"))
            }
        } catch {
            return .fail(SidecarError(code: -32603, message: String(describing: error)))
        }
    }

    private func param(_ params: SidecarValue?, _ key: String) throws -> String {
        guard let v = params?.key(key)?.string else {
            throw SidecarServerError.unknownRegion("missing param '\(key)'")
        }
        return v
    }

    private func write(_ env: SidecarEnvelope) {
        try? stdout.write(contentsOf: encodeLine(env))
    }

    private func encodeLine(_ env: SidecarEnvelope) -> Data {
        let data = (try? JSONEncoder().encode(env)) ?? Data()
        var line = data
        line.append(0x0A)
        return line
    }
}

// MARK: - Entry

/// Plugin-side entry point: run a plugin bundle as a sidecar. The
/// process answers the host RPC protocol on stdin/stdout until the host
/// closes stdin.
public enum SidecarServer {
    /// Blocks until the host closes stdin (or the process is killed).
    public static func run(plugin: any SidebarTabPlugin) async throws {
        let endpoint = SidecarEndpoint(plugin: plugin)
        try await endpoint.run()
    }
}
