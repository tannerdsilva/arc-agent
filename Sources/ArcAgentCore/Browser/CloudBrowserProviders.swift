import Foundation
import AsyncHTTPClient
import NIOCore
import NIOHTTP1

extension Dictionary where Key == String, Value == Any {
    fileprivate func string(_ key: String) -> String { (self[key] as? String) ?? "" }
}

// MARK: - Cloud browser sessions (reference `plugins/browser/<name>/provider.py`)

/// Session metadata returned by a cloud provider (reference contract).
public struct BrowserCloudSession: Sendable, Equatable {
    public let sessionName: String
    public let sessionID: String
    public let cdpURL: String
    public let expiresAt: String?
    public let features: [String: Bool]
    public let externalCallID: String?

    public init(sessionName: String, sessionID: String, cdpURL: String,
                expiresAt: String? = nil, features: [String: Bool] = [:],
                externalCallID: String? = nil) {
        self.sessionName = sessionName
        self.sessionID = sessionID
        self.cdpURL = cdpURL
        self.expiresAt = expiresAt
        self.features = features
        self.externalCallID = externalCallID
    }
}

/// Cloud browser backend (reference `BrowserProvider` ABC).
public protocol BrowserSessionProvider: Sendable {
    var name: String { get }
    func isAvailable() async -> Bool
    func createSession(taskID: String) async throws -> BrowserCloudSession
    func closeSession(sessionID: String) async throws -> Bool
    func emergencyCleanup() async
}

/// Shared AsyncHTTPClient for browser cloud calls.
enum BrowserHTTP {
    static let client = HTTPClient(eventLoopGroupProvider: .singleton)
}
public struct BrowserbaseSessionProvider: BrowserSessionProvider {
    public let name = "browserbase"

    public init() {}

    public func isAvailable() async -> Bool {
        ProcessInfo.processInfo.environment["BROWSERBASE_API_KEY"]?.isEmpty == false
            && ProcessInfo.processInfo.environment["BROWSERBASE_PROJECT_ID"]?.isEmpty == false
    }

    private var apiKey: String { ProcessInfo.processInfo.environment["BROWSERBASE_API_KEY"] ?? "" }
    private var projectID: String { ProcessInfo.processInfo.environment["BROWSERBASE_PROJECT_ID"] ?? "" }
    private var baseURL: String {
        ProcessInfo.processInfo.environment["BROWSERBASE_BASE_URL"] ?? "https://api.browserbase.com"
    }

    public func createSession(taskID: String) async throws -> BrowserCloudSession {
        guard !apiKey.isEmpty, !projectID.isEmpty else {
            throw CDPError.commandFailed("Browserbase requires BROWSERBASE_API_KEY and BROWSERBASE_PROJECT_ID")
        }
        let env = ProcessInfo.processInfo.environment
        var config: [String: Any] = ["projectId": projectID]
        if (env["BROWSERBASE_PROXIES"] ?? "true").lowercased() != "false" {
            config["proxies"] = true
        }
        if env["BROWSERBASE_KEEP_ALIVE"]?.lowercased() == "true" {
            config["keepAlive"] = true
        }
        if env["BROWSERBASE_ADVANCED_STEALTH"]?.lowercased() == "true" {
            config["browserSettings"] = ["advancedStealth": true]
        }
        if let raw = env["BROWSERBASE_SESSION_TIMEOUT"], let ms = Int(raw), ms > 0 {
            config["timeout"] = ms
        }
        let data = try await BrowserCloudAPI.postJSON(
            url: "\(baseURL)/v1/sessions",
            headers: ["Content-Type": "application/json", "X-BB-API-Key": apiKey],
            body: config
        )
        let sessionID = data.string("id")
        let cdpURL = data.string("connectUrl") ?? data.string("cdpUrl") ?? ""
        guard !sessionID.isEmpty, !cdpURL.isEmpty else {
            throw CDPError.commandFailed("Browserbase session created without connect URL")
        }
        return BrowserCloudSession(
            sessionName: "arc_\(taskID)_\(UUID().uuidString.prefix(8))",
            sessionID: sessionID,
            cdpURL: cdpURL,
            features: ["basic_stealth": true, "proxies": config["proxies"] as? Bool ?? false]
        )
    }

    public func closeSession(sessionID: String) async throws -> Bool {
        _ = try await BrowserCloudAPI.delete(url: "\(baseURL)/v1/sessions/\(sessionID)",
                                             headers: ["X-BB-API-Key": apiKey])
        return true
    }

    public func emergencyCleanup() async {}
}

/// Browser Use cloud (reference `plugins/browser/browser_use/provider.py`).
public struct BrowserUseSessionProvider: BrowserSessionProvider {
    public let name = "browser-use"

    public init() {}

    public func isAvailable() async -> Bool {
        ProcessInfo.processInfo.environment["BROWSER_USE_API_KEY"]?.isEmpty == false
    }

    private var apiKey: String { ProcessInfo.processInfo.environment["BROWSER_USE_API_KEY"] ?? "" }
    private var baseURL: String {
        ProcessInfo.processInfo.environment["BROWSER_USE_BASE_URL"] ?? "https://api.browser-use.com/api/v3"
    }

    public func createSession(taskID: String) async throws -> BrowserCloudSession {
        guard !apiKey.isEmpty else {
            throw CDPError.commandFailed("Browser Use requires BROWSER_USE_API_KEY")
        }
        let data = try await BrowserCloudAPI.postJSON(
            url: "\(baseURL)/browsers",
            headers: ["Content-Type": "application/json", "X-Browser-Use-API-Key": apiKey],
            body: [:]
        )
        let sessionID = data.string("id")
        let cdpURL = data.string("cdpUrl") ?? data.string("connectUrl") ?? ""
        guard !sessionID.isEmpty, !cdpURL.isEmpty else {
            throw CDPError.commandFailed("Browser Use session created without CDP URL")
        }
        return BrowserCloudSession(
            sessionName: "arc_\(taskID)_\(UUID().uuidString.prefix(8))",
            sessionID: sessionID,
            cdpURL: cdpURL
        )
    }

    public func closeSession(sessionID: String) async throws -> Bool {
        _ = try await BrowserCloudAPI.delete(url: "\(baseURL)/browsers/\(sessionID)",
                                             headers: ["X-Browser-Use-API-Key": apiKey])
        return true
    }

    public func emergencyCleanup() async {}
}

/// Firecrawl cloud browser (reference `plugins/browser/firecrawl/provider.py`).
public struct FirecrawlSessionProvider: BrowserSessionProvider {
    public let name = "firecrawl"

    public init() {}

    public func isAvailable() async -> Bool {
        ProcessInfo.processInfo.environment["FIRECRAWL_API_KEY"]?.isEmpty == false
    }

    private var apiKey: String { ProcessInfo.processInfo.environment["FIRECRAWL_API_KEY"] ?? "" }
    private var apiURL: String {
        ProcessInfo.processInfo.environment["FIRECRAWL_API_URL"] ?? "https://api.firecrawl.dev"
    }

    public func createSession(taskID: String) async throws -> BrowserCloudSession {
        guard !apiKey.isEmpty else {
            throw CDPError.commandFailed("FIRECRAWL_API_KEY environment variable is required")
        }
        let ttl = Int(ProcessInfo.processInfo.environment["FIRECRAWL_BROWSER_TTL"] ?? "300") ?? 300
        let data = try await BrowserCloudAPI.postJSON(
            url: "\(apiURL)/v2/browser",
            headers: ["Content-Type": "application/json", "Authorization": "Bearer \(apiKey)"],
            body: ["ttl": ttl]
        )
        let sessionID = data.string("id")
        let cdpURL = data.string("cdpUrl")
        guard !sessionID.isEmpty, !cdpURL.isEmpty else {
            throw CDPError.commandFailed("Firecrawl session created without CDP URL")
        }
        return BrowserCloudSession(
            sessionName: "arc_\(taskID)_\(UUID().uuidString.prefix(8))",
            sessionID: sessionID,
            cdpURL: cdpURL,
            features: ["firecrawl": true]
        )
    }

    public func closeSession(sessionID: String) async throws -> Bool {
        _ = try await BrowserCloudAPI.delete(url: "\(apiURL)/v2/browser/\(sessionID)",
                                             headers: ["Authorization": "Bearer \(apiKey)"])
        return true
    }

    public func emergencyCleanup() async {}
}

/// JSON helper for the three cloud APIs (flat key lookup; tolerant casts).
struct BrowserJSONBox {
    let root: [String: Any]
    init(_ root: [String: Any]) { self.root = root }
    func string(_ key: String) -> String { (root[key] as? String) ?? "" }
}

/// Coordinator: create a cloud session, bind the local CDP driver to the
/// session's CDP endpoint (reference: cloud sessions drive via agent-browser
/// with the returned CDP URL), and remember it for `browser_close`.
public actor BrowserCloudCoordinator {
    public static let shared = BrowserCloudCoordinator()

    private var providers: [String: any BrowserSessionProvider] = [
        "browserbase": BrowserbaseSessionProvider(),
        "browser-use": BrowserUseSessionProvider(),
        "firecrawl": FirecrawlSessionProvider(),
    ]
    private var activeSession: BrowserCloudSession?

    public func providerNames() -> [String] {
        Array(providers.keys).sorted()
    }

    /// Create a cloud session and make its CDP endpoint the active browser.
    public func connect(providerName: String, taskID: String = UUID().uuidString) async throws -> String {
        let key = providers.keys.first { $0 == providerName || $0.replacingOccurrences(of: "-", with: "_") == providerName }
            ?? providerName
        guard let provider = providers[key] ?? providers[providerName] else {
            throw CDPError.commandFailed("Unknown browser provider '\(providerName)' (available: \(providerNames().joined(separator: ", ")))")
        }
        guard await provider.isAvailable() else {
            throw CDPError.commandFailed("Provider '\(providerName)' unavailable (check its *_API_KEY env vars)")
        }
        let session = try await provider.createSession(taskID: taskID)
        activeSession = session
        let driver = CDPBrowserProvider(endpoint: URL(string: session.cdpURL))
        await BrowserRegistry.shared.register(driver)
        return session.cdpURL
    }

    /// Close the active cloud session (reference `browser_close`).
    public func close() async -> String {
        guard let session = activeSession else {
            return "No active cloud session."
        }
        activeSession = nil
        for provider in providers.values {
            if (try? await provider.closeSession(sessionID: session.sessionID)) == true {
                break
            }
        }
        // Fall back to the local CDP provider after releasing the cloud one.
        await BrowserRegistry.shared.register(CDPBrowserProvider())
        return "Closed browser session \(session.sessionID)"
    }

    public func activeSessionInfo() -> BrowserCloudSession? { activeSession }
}

// MARK: - HTTP helpers

enum BrowserCloudAPI {
    static func postJSON(url: String, headers: [String: String], body: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await send(url: url, method: .POST, headers: headers, body: data)
    }

    static func delete(url: String, headers: [String: String]) async throws -> [String: Any] {
        try await send(url: url, method: .DELETE, headers: headers, body: nil)
    }

    static func send(url: String, method: HTTPMethod, headers: [String: String], body: Data?) async throws -> [String: Any] {
        var h = HTTPHeaders()
        for (k, v) in headers { h.add(name: k, value: v) }
        let request = try HTTPClient.Request(
            url: url, method: method, headers: h,
            body: body.map { .byteBuffer(ByteBuffer(bytes: $0)) }
        )
        let response = try await BrowserHTTP.client.execute(request: request, deadline: .now() + .seconds(30)).get()
        guard (200..<300).contains(response.status.code) else {
            throw CDPError.commandFailed("HTTP \(response.status.code) from \(url)")
        }
        let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body ?? ByteBuffer())) as? [String: Any] ?? [:]
        return json
    }
}
