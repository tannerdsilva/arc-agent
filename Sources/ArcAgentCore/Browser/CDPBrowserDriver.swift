import Foundation

// MARK: - Browser provider registry + CDP driver (Hermes browser_registry)

/// A browser provider drives a browser; implementations are HTTP/WebSocket
/// based so a static Swift binary can ship them.
public protocol BrowserProvider: Sendable {
    var name: String { get }
    func navigate(url: String) async throws -> String
    func snapshot() async throws -> String
    func click(selector: String) async throws -> String
    func type(selector: String, text: String) async throws -> String
    func press(key: String) async throws -> String
    func scroll(direction: String) async throws -> String
    func back() async throws -> String
}

/// Name → provider registry (Hermes browser_registry): providers register,
/// exactly one is active (configured via `BROWSER_PROVIDER`, default "cdp").
/// An actor per the First Law.
public actor BrowserRegistry {
    public static let shared = BrowserRegistry()
    private var providers: [String: any BrowserProvider] = [:]

    public func register(_ provider: any BrowserProvider) {
        providers[provider.name] = provider
    }

    public func active() -> (any BrowserProvider)? {
        let name = ProcessInfo.processInfo.environment["BROWSER_PROVIDER"] ?? "cdp"
        return providers[name] ?? providers["cdp"]
    }

    public func available() -> [String] {
        Array(providers.keys)
    }
}

/// Stateless CDP command channel: one WebSocket, sequential command ids,
/// response correlation via a continuation table.
public final class CDPCommandChannel: @unchecked Sendable {
    private var socket: URLSessionWebSocketTask?
    private var readerTask: Task<Void, Never>?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    public init() {}

    public var isConnected: Bool { socket != nil }

    public func connect(endpoint: URL) async throws {
        try await disconnect()
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: endpoint)
        socket = task
        task.resume()
        startReader()
        // Verify the socket is alive by requesting the browser version.
        _ = try await send(method: "Browser.getVersion", params: [:])
    }

    public func disconnect() async {
        readerTask?.cancel()
        readerTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    public func send(method: String, params: [String: Any]) async throws -> [String: Any] {
        guard let socket else { throw CDPError.notConnected }
        let id = nextID
        nextID += 1
        let payload: [String: Any] = ["id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await socket.send(.string(String(data: data, encoding: .utf8)!))
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
        }
    }

    /// Poll the socket for matching responses (loop-tap style: drain
    /// continuously in a task).
    public func startReader() {
        guard let socket else { return }
        readerTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    guard case .string(let text) = message,
                          let data = text.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let id = json["id"] as? Int else { continue }
                    if let cont = self?.pending.removeValue(forKey: id) {
                        if let error = json["error"] as? [String: Any] {
                            cont.resume(throwing: CDPError.commandFailed(error["message"] as? String ?? "unknown"))
                        } else {
                            cont.resume(returning: json["result"] as? [String: Any] ?? [:])
                        }
                    }
                } catch {
                    if let self {
                        for cont in self.pending.values { cont.resume(throwing: error) }
                        self.pending.removeAll()
                    }
                    return
                }
            }
        }
    }
}

public enum CDPError: Error, CustomStringConvertible {
    case notConnected
    case commandFailed(String)

    public var description: String {
        switch self {
        case .notConnected: return "CDP not connected (start Chrome with --remote-debugging-port=9222)"
        case .commandFailed(let msg): return "CDP command failed: \(msg)"
        }
    }
}

/// Chromium CDP-over-WebSocket browser provider (Hermes' CDP-based browser
/// provider; no Playwright/Node needed — talks raw CDP via Foundation
/// WebSocket). Configure via `BROWSER_CDP_URL` (default
/// `ws://localhost:9222/devtools/browser`).
public final class CDPBrowserProvider: BrowserProvider, @unchecked Sendable {

    public let name = "cdp"
    private let channel = CDPCommandChannel()
    private let endpoint: URL
    private static var pageTargetID: String?

    public init(endpoint: URL? = nil) {
        let env = ProcessInfo.processInfo.environment["BROWSER_CDP_URL"]
            ?? "ws://localhost:9222/devtools/browser"
        self.endpoint = endpoint ?? URL(string: env)!
    }

    /// Open the newest page target and attach. Idempotent per process.
    private func ensureAttached() async throws -> String {
        if let id = CDPBrowserProvider.pageTargetID {
            return id
        }
        if !channel.isConnected {
            try await channel.connect(endpoint: endpoint)
        }
        let version = try await channel.send(method: "Target.getTargets", params: [:])
        let targets = version["targetInfos"] as? [[String: Any]] ?? []
        guard let page = targets.first(where: { ($0["type"] as? String) == "page" }) else {
            throw CDPError.commandFailed("no page target found")
        }
        let targetID = page["targetId"] as? String ?? ""
        CDPBrowserProvider.pageTargetID = targetID
        return targetID
    }

    private func attach(id: String) async throws {
        _ = try await channel.send(method: "Target.attachToTarget", params: ["targetId": id, "flatten": true])
    }

    public func navigate(url: String) async throws -> String {
        let id = try await ensureAttached()
        try await attach(id: id)
        _ = try await channel.send(method: "Page.navigate", params: ["url": url])
        return "Navigated to \(url)"
    }

    public func snapshot() async throws -> String {
        let id = try await ensureAttached()
        try await attach(id: id)
        let result = try await channel.send(method: "Runtime.evaluate", params: [
            "expression": "document.body ? document.body.innerText : ''",
            "returnByValue": true,
        ])
        let value = (result["result"] as? [String: Any])?["value"] as? String ?? ""
        return value.isEmpty ? "(empty page)" : value
    }

    public func click(selector: String) async throws -> String {
        let id = try await ensureAttached()
        try await attach(id: id)
        let js = "document.querySelector(\(CDPBrowserProvider.jsonString(selector))) && document.querySelector(\(CDPBrowserProvider.jsonString(selector))).click()"
        _ = try await channel.send(method: "Runtime.evaluate", params: ["expression": js])
        return "Clicked \(selector)"
    }

    public func type(selector: String, text: String) async throws -> String {
        let id = try await ensureAttached()
        try await attach(id: id)
        let js = """
        (() => {
          const el = document.querySelector(\(CDPBrowserProvider.jsonString(selector)));
          if (!el) return false;
          el.focus();
          el.value = \(CDPBrowserProvider.jsonString(text));
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return true;
        })()
        """
        _ = try await channel.send(method: "Runtime.evaluate", params: ["expression": js])
        return "Typed into \(selector)"
    }

    public func press(key: String) async throws -> String {
        let id = try await ensureAttached()
        try await attach(id: id)
        let js = """
        (() => {
          const ev = new KeyboardEvent('keydown', { key: \(CDPBrowserProvider.jsonString(key)), bubbles: true });
          document.activeElement ? document.activeElement.dispatchEvent(ev) : document.body.dispatchEvent(ev);
          return true;
        })()
        """
        _ = try await channel.send(method: "Runtime.evaluate", params: ["expression": js])
        return "Pressed \(key)"
    }

    public func scroll(direction: String) async throws -> String {
        let id = try await ensureAttached()
        try await attach(id: id)
        let delta = direction == "up" ? "-800" : "800"
        let js = "window.scrollBy(0, \(delta)); true"
        _ = try await channel.send(method: "Runtime.evaluate", params: ["expression": js])
        return "Scrolled \(direction)"
    }

    public func back() async throws -> String {
        let id = try await ensureAttached()
        try await attach(id: id)
        _ = try await channel.send(method: "Page.navigate", params: ["url": "about:blank"])
        // Best-effort history back via JavaScript.
        _ = try await channel.send(method: "Runtime.evaluate", params: ["expression": "history.back(); true"])
        return "Went back"
    }

    static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else {
            return "\"\""
        }
        return String(data: data, encoding: .utf8) ?? "\"\""
    }
}

// MARK: - Browser tools (Hermes browser_* tool family)

public enum BrowserTools {
    static func requireProvider() async throws -> any BrowserProvider {
        guard let provider = await BrowserRegistry.shared.active() else {
            throw CDPError.notConnected
        }
        return provider
    }

    public static let navigate = ToolEntry(
        name: "browser_navigate",
        toolset: "browser",
        description: "Navigate the browser to a URL (CDP provider).",
        schema: .object(properties: ["url": .string(description: "Absolute URL to open")], required: ["url"]),
        handler: { args in
            let provider = try await requireProvider()
            let url: String = try MediaTools.required(args, key: "url")
            return try await provider.navigate(url: url)
        },
        emoji: "🧭"
    )

    public static let snapshot = ToolEntry(
        name: "browser_snapshot",
        toolset: "browser",
        description: "Read the visible text of the current page (CDP provider).",
        schema: .object(properties: [:]),
        handler: { _ in
            let provider = try await requireProvider()
            return try await provider.snapshot()
        },
        emoji: "📄"
    )

    public static let click = ToolEntry(
        name: "browser_click",
        toolset: "browser",
        description: "Click an element by CSS selector (CDP provider).",
        schema: .object(properties: ["selector": .string(description: "CSS selector")], required: ["selector"]),
        handler: { args in
            let provider = try await requireProvider()
            let selector: String = try MediaTools.required(args, key: "selector")
            return try await provider.click(selector: selector)
        },
        emoji: "🖱️"
    )

    public static let type = ToolEntry(
        name: "browser_type",
        toolset: "browser",
        description: "Type text into an input by CSS selector (CDP provider).",
        schema: .object(properties: [
            "selector": .string(description: "CSS selector"),
            "text": .string(description: "Text to type"),
        ], required: ["selector", "text"]),
        handler: { args in
            let provider = try await requireProvider()
            let selector: String = try MediaTools.required(args, key: "selector")
            let text: String = try MediaTools.required(args, key: "text")
            return try await provider.type(selector: selector, text: text)
        },
        emoji: "⌨️"
    )

    public static let press = ToolEntry(
        name: "browser_press",
        toolset: "browser",
        description: "Press a keyboard key on the focused element (CDP provider).",
        schema: .object(properties: ["key": .string(description: "Key name, e.g. Enter")], required: ["key"]),
        handler: { args in
            let provider = try await requireProvider()
            let key: String = try MediaTools.required(args, key: "key")
            return try await provider.press(key: key)
        },
        emoji: "⌨️"
    )

    public static let scroll = ToolEntry(
        name: "browser_scroll",
        toolset: "browser",
        description: "Scroll the page up or down (CDP provider).",
        schema: .object(properties: ["direction": .string(description: "up or down")], required: ["direction"]),
        handler: { args in
            let provider = try await requireProvider()
            let direction: String = try MediaTools.required(args, key: "direction")
            return try await provider.scroll(direction: direction)
        },
        emoji: "📜"
    )

    public static let back = ToolEntry(
        name: "browser_back",
        toolset: "browser",
        description: "Navigate back in browser history (CDP provider).",
        schema: .object(properties: [:]),
        handler: { _ in
            let provider = try await requireProvider()
            return try await provider.back()
        },
        emoji: "↩️"
    )
}
