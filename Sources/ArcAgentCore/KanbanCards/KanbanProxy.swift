import Foundation

// ==========================================================================
// KanbanProxy — the worker→daemon card-write proxy.
//
// A dispatch worker is a separate process that would otherwise open its
// own tessera tunnel. Because every process loads the same
// `~/.arc/.env` WireGuard static key, that second tunnel rotates the
// relay's peer index and invalidates the daemon's established session —
// the "echo never landed — forcing reconnect" cascade. When a local
// daemon is already up, the worker routes its `kanban` tool calls
// through the daemon's HTTP API instead (`POST /v1/kanban`): the daemon
// executes the verb with its own store over its own tunnel, so exactly
// one process per machine ever writes tessera events for cards.
//
// Discovery mirrors the daemon's own resolution: the API surface comes
// from `<arcHome>/daemon.json` → `api{enabled, host, port}` with env
// overrides `API_HOST`/`API_PORT` (the worker inherits the daemon's
// `ARC_HOME`). The bearer token comes from `<arcHome>/.env` →
// `ARC_KANBAN_PROXY_TOKEN`. Any miss — no token, api disabled, dead
// endpoint, auth rejected, timeout — returns nil and the caller falls
// back to the local store path unchanged.
// ==========================================================================

struct KanbanProxy: Sendable, Equatable {
    let host: String
    let port: Int
    let token: String

    // MARK: Resolution

    /// Resolve the proxy target from the current arc home. Returns nil
    /// when either half (endpoint or token) is missing.
    static func resolve(
        arcHome: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> KanbanProxy? {
        let home = arcHome ?? ArcHome.root
        let dotenv = loadDotEnv(home.appendingPathComponent(".env"))
        guard let token = dotenv["ARC_KANBAN_PROXY_TOKEN"], !token.isEmpty else { return nil }

        // daemon.json → api block; env overrides win (reference convention).
        var dict: [String: Any] = [:]
        if let data = try? Data(contentsOf: home.appendingPathComponent("daemon.json")),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = parsed
        }
        let api = dict["api"] as? [String: Any] ?? [:]
        let enabled = api["enabled"] as? Bool ?? true
        guard enabled else { return nil }
        let host = environment["API_HOST"] ?? (api["host"] as? String) ?? "127.0.0.1"
        let port = Int(environment["API_PORT"] ?? "") ?? (api["port"] as? Int) ?? 8080
        return KanbanProxy(host: host, port: port, token: token)
    }

    // MARK: Forwarding

    /// Forward a `kanban` tool invocation to the daemon. Returns nil on
    /// any transport failure so the caller can fall back locally; a
    /// delivered response is the daemon's tool output string verbatim.
    func forward(args: [String: Any], env: [String: String]) async -> String? {
        let payload: [String: Any] = ["args": args, "env": env]
        // Loop through JSONSerialization: tool args are [String: Any].
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var request = URLRequest(url: URL(string: "http://\(host):\(port)/v1/kanban")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = decoded["output"] as? String
        else { return nil }
        return output
    }
}
