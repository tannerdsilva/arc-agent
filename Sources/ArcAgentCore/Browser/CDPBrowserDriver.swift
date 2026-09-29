import Foundation

// MARK: - Browser provider registry + CDP driver (reference browser_registry)

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

/// Name → provider registry (reference browser_registry): providers register,
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
    private let events = CDPEventLog()
    /// Runtime/Page domains enabled for event capture (idempotent).
    private var domainsEnabled = false

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

    /// Enable Runtime.page console/dialog event capture (reference:
    /// console messages + JS dialogs are captured while the browser runs).
    public func enableEventCapture() async throws {
        if !domainsEnabled {
            _ = try await send(method: "Runtime.enable", params: [:])
            _ = try await send(method: "Page.enable", params: [:])
            domainsEnabled = true
        }
    }

    /// Drain buffered console messages; `clear` empties the buffer.
    public func drainConsole(clear: Bool) async -> [String] {
        await events.drainConsole(clear: clear)
    }

    /// Buffered native JS dialogs (alert/confirm/prompt/beforeunload).
    public func pendingDialogs() async -> [[String: Any]] {
        await events.dialogs()
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
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    // Event notifications carry a method and no id — route to
                    // the console/dialog buffers (CDP internals exception:
                    // @unchecked Sendable + actor buffering).
                    if let method = json["method"] as? String, json["id"] == nil {
                        await self?.routeEvent(method: method, json: json)
                        continue
                    }
                    guard let id = json["id"] as? Int else { continue }
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

    private func routeEvent(method: String, json: [String: Any]) async {
        let params = json["params"] as? [String: Any] ?? [:]
        switch method {
        case "Runtime.consoleAPICalled":
            let type = params["type"] as? String ?? "log"
            let args = params["args"] as? [[String: Any]] ?? []
            let text = args.compactMap { arg -> String? in
                if let v = arg["value"] { return String(describing: v) }
                if let d = arg["description"] as? String { return d }
                return nil
            }.joined(separator: " ")
            await events.appendConsole(type: type, text: text)

        case "Runtime.exceptionThrown":
            let details = params["exceptionDetails"] as? [String: Any] ?? [:]
            let text = details["text"] as? String ?? "uncaught exception"
            let exception = details["exception"] as? [String: Any] ?? [:]
            let desc = exception["description"] as? String ?? ""
            let value = exception["value"] as? String ?? ""
            await events.appendConsole(type: "error", text: desc.isEmpty ? (value.isEmpty ? text : "\(text): \(value)") : desc)

        case "Page.javascriptDialogOpening":
            await events.appendDialog(params: [
                "type": params["type"] as? String ?? "alert",
                "message": params["message"] as? String ?? "",
                "url": params["url"] as? String ?? "",
            ])

        case "Runtime.executionContextsCleared":
            await events.clearConsole()

        default:
            break
        }
    }
}

/// Actor-buffered console/dialog events (CDP internals exception: the
/// reader task appends; tools drain).
actor CDPEventLog {
    private var consoleBuffer: [(type: String, text: String)] = []
    private var dialogBuffer: [[String: Any]] = []

    func appendConsole(type: String, text: String) {
        guard !text.isEmpty else { return }
        consoleBuffer.append((type, text))
        if consoleBuffer.count > 1_000 { consoleBuffer.removeFirst(consoleBuffer.count - 1_000) }
    }

    func appendDialog(params: [String: Any]) {
        dialogBuffer.append(params)
        if dialogBuffer.count > 20 { dialogBuffer.removeFirst(dialogBuffer.count - 20) }
    }

    func clearConsole() { consoleBuffer.removeAll() }

    func drainConsole(clear: Bool) -> [String] {
        let lines = consoleBuffer.map { "[\($0.type)] \($0.text)" }
        if clear { consoleBuffer.removeAll() }
        return lines
    }

    func dialogs() -> [[String: Any]] { dialogBuffer }
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

/// Chromium CDP-over-WebSocket browser provider (reference' CDP-based browser
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
        // Console/dialog capture (reference: always-on while connected).
        try await channel.enableEventCapture()
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

    // MARK: - Extended CDP capabilities (reference browser_* family)

    /// Evaluate a JS expression in the page context; results are serialized
    /// to JSON (reference browser_console `expression` path).
    public func evaluate(expression: String) async throws -> String {
        let id = try await ensureAttached()
        try await attach(id: id)
        let result = try await channel.send(method: "Runtime.evaluate", params: [
            "expression": expression,
            "returnByValue": true,
            "awaitPromise": true,
        ])
        guard let remote = result["result"] as? [String: Any] else { return "undefined" }
        if let value = remote["value"] as? String { return value }
        if remote["value"] != nil {
            let data = try JSONSerialization.data(withJSONObject: remote["value"] as Any, options: [.fragmentsAllowed])
            return String(data: data, encoding: .utf8) ?? "undefined"
        }
        return remote["description"] as? String ?? "undefined"
    }

    /// Read console output + JS errors (reference browser_console).
    public func consoleMessages(clear: Bool) async throws -> String {
        let id = try await ensureAttached()
        try await attach(id: id)
        let lines = await channel.drainConsole(clear: clear)
        return lines.isEmpty ? "(no console messages)" : lines.joined(separator: "\n")
    }

    /// List images on the page with URLs and alt text (reference browser_get_images).
    public func listImages() async throws -> String {
        let js = """
        JSON.stringify(Array.from(document.images).map(i => ({
          src: i.currentSrc || i.src || '',
          alt: i.alt || ''
        })))
        """
        let raw = try await evaluate(expression: js)
        guard let data = raw.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return "(no images)"
        }
        if items.isEmpty { return "(no images)" }
        return items.map { "\($0["alt"] as? String ?? "") — \($0["src"] as? String ?? "")" }
            .joined(separator: "\n")
    }

    /// Capture a screenshot of the page, save as PNG, return the path
    /// (reference browser_vision screenshot half).
    public func screenshot() async throws -> String {
        let id = try await ensureAttached()
        try await attach(id: id)
        let result = try await channel.send(method: "Page.captureScreenshot", params: [
            "format": "png",
            "fromSurface": true,
        ])
        guard let base64 = result["data"] as? String,
              let data = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]) else {
            throw CDPError.commandFailed("no screenshot data returned")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-browser-shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("shot-\(Int(Date().timeIntervalSince1970)).png")
        try data.write(to: path)
        return path.path
    }

    /// Buffered native JS dialogs (reference snapshot `pending_dialogs`).
    public func dialogs() async throws -> [[String: Any]] {
        let id = try await ensureAttached()
        try await attach(id: id)
        return await channel.pendingDialogs()
    }

    /// Respond to a blocking native dialog (reference browser_dialog).
    public func handleDialog(accept: Bool, promptText: String) async throws -> String {
        let id = try await ensureAttached()
        try await attach(id: id)
        var params: [String: Any] = ["accept": accept]
        if accept, !promptText.isEmpty { params["promptText"] = promptText }
        _ = try await channel.send(method: "Page.handleJavaScriptDialog", params: params)
        return accept ? "Dialog accepted\(promptText.isEmpty ? "" : ": \"\(promptText)\"")" : "Dialog dismissed"
    }

    /// Raw CDP passthrough (reference browser_cdp escape hatch).
    public func rawCDP(method: String, params: [String: Any]) async throws -> String {
        let id = try await ensureAttached()
        try await attach(id: id)
        let result = try await channel.send(method: method, params: params)
        let data = try JSONSerialization.data(withJSONObject: result as Any, options: [.prettyPrinted, .fragmentsAllowed])
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - Browser tools (reference browser_* tool family)

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

    static func requireCDP() async throws -> CDPBrowserProvider {
        let provider = try await requireProvider()
        guard let cdp = provider as? CDPBrowserProvider else {
            throw CDPError.commandFailed("this operation requires the CDP browser provider")
        }
        return cdp
    }

    public static let console = ToolEntry(
        name: "browser_console",
        toolset: "browser",
        description: "Get browser console output and JavaScript errors from the current page. "
            + "Returns console.log/warn/error/info messages and uncaught JS exceptions. Use this "
            + "to detect silent JavaScript errors, failed API calls, and application warnings. "
            + "Requires browser_navigate to be called first. When 'expression' is provided, "
            + "evaluates JavaScript in the page context and returns the result — use this for "
            + "DOM inspection, reading page state, or extracting data programmatically.",
        schema: .object(properties: [
            "clear": .boolean(description: "If true, clear the message buffers after reading"),
            "expression": .string(description: "JavaScript expression to evaluate in the page context. "
                + "Runs in the browser like DevTools console — full access to DOM, window, document. "
                + "Return values are serialized to JSON. Example: 'document.title' or "
                + "'document.querySelectorAll(\"a\").length'"),
        ]),
        handler: { args in
            let cdp = try await requireCDP()
            if let expr = args["expression"] as? String, !expr.isEmpty {
                return try await cdp.evaluate(expression: expr)
            }
            let clear = (args["clear"] as? Bool) ?? false
            return try await cdp.consoleMessages(clear: clear)
        },
        emoji: "🖥️"
    )

    public static let getImages = ToolEntry(
        name: "browser_get_images",
        toolset: "browser",
        description: "Get a list of all images on the current page with their URLs and alt text. "
            + "Useful for finding images to analyze with the vision tool. Requires browser_navigate "
            + "to be called first.",
        schema: .object(properties: [:]),
        handler: { _ in
            let cdp = try await requireCDP()
            return try await cdp.listImages()
        },
        emoji: "🖼️"
    )

    public static let vision = ToolEntry(
        name: "browser_vision",
        toolset: "browser",
        description: "Take a screenshot of the current page so you can inspect it visually (CDP "
            + "provider). Returns a screenshot_path you can share with the user by including "
            + "MEDIA:<screenshot_path> in your response. Requires browser_navigate to be called first.",
        schema: .object(properties: [
            "question": .string(description: "What you want to know about the page visually. "
                + "Be specific about what you're looking for."),
        ], required: ["question"]),
        handler: { _ in
            let cdp = try await requireCDP()
            return try await cdp.screenshot()
        },
        emoji: "📸"
    )

    public static let dialog = ToolEntry(
        name: "browser_dialog",
        toolset: "browser",
        description: "Respond to a native JavaScript dialog (alert / confirm / prompt / "
            + "beforeunload) that is currently blocking the page. Call browser_snapshot first — if "
            + "a dialog is open, it appears in the output. Then call this tool with action='accept' "
            + "or action='dismiss'. For prompt dialogs pass prompt_text to supply the response "
            + "string; ignored for alert/confirm/beforeunload (CDP provider).",
        schema: .object(properties: [
            "action": .enum(description: "accept or dismiss", values: ["accept", "dismiss"]),
            "prompt_text": .string(description: "Response string for prompt dialogs"),
        ], required: ["action"]),
        handler: { args in
            let cdp = try await requireCDP()
            let action: String = try MediaTools.required(args, key: "action")
            let text: String = (args["prompt_text"] as? String) ?? ""
            return try await cdp.handleDialog(accept: action == "accept", promptText: text)
        },
        emoji: "🗔"
    )

    public static let cdp = ToolEntry(
        name: "browser_cdp",
        toolset: "browser",
        description: "Send a raw Chrome DevTools Protocol (CDP) command. Escape hatch for browser "
            + "operations not covered by browser_navigate, browser_click, browser_console, etc. "
            + "Examples: method='Target.getTargets'; method='Network.getAllCookies'; "
            + "method='Page.handleJavaScriptDialog' with {'accept': true}; method='Runtime.evaluate' "
            + "with {'expression': '...', 'returnByValue': true}. Requires a reachable CDP endpoint.",
        schema: .object(properties: [
            "method": .string(description: "CDP method, e.g. 'Target.getTargets'"),
            "params": .object(description: "CDP params object", properties: [:]),
        ], required: ["method"]),
        handler: { args in
            let cdp = try await requireCDP()
            let method: String = try MediaTools.required(args, key: "method")
            let params = args["params"] as? [String: Any] ?? [:]
            return try await cdp.rawCDP(method: method, params: params)
        },
        emoji: "🔧"
    )
}
