import Foundation

/// MCP server configuration (reference `mcp_servers.<name>` entry).
public struct MCPServerConfig: Codable, Sendable, Equatable {
    /// The executable to launch. Resolved against `PATH` by the transport, so a
    /// bare name (`arc`) and an absolute path both work. A package-manager
    /// launcher is refused before any spawn — see ``MCPServerLaunchPolicy``.
    public var command: String
    /// Arguments passed to the command.
    public var args: [String]
    /// Extra environment variables merged over the sanitized process env.
    public var env: [String: String]
    /// Per-tool-call timeout in seconds (reference default 300). Applied as the
    /// client's `callTimeout`.
    public var timeout: Double
    /// Initial connection timeout in seconds (reference default 60). Applied as
    /// the client's `negotiationTimeout`.
    public var connectTimeout: Double

    public init(
        command: String,
        args: [String] = [],
        env: [String: String] = [:],
        timeout: Double = 300,
        connectTimeout: Double = 60
    ) {
        self.command = command
        self.args = args
        self.env = env
        self.timeout = timeout
        self.connectTimeout = connectTimeout
    }

    private enum CodingKeys: String, CodingKey {
        case command, args, env, timeout, connectTimeout
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        command = try c.decode(String.self, forKey: .command)
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        timeout = try c.decodeIfPresent(Double.self, forKey: .timeout) ?? 300
        connectTimeout = try c.decodeIfPresent(Double.self, forKey: .connectTimeout) ?? 60
    }

    /// Environment sanitization (reference `_build_safe_env`): strip the agent's
    /// own credential variables before launching an external MCP server.
    ///
    /// The transport spawns the child with exactly this map
    /// (`inheritParentEnvironment: false`), because a subprocess shares the host
    /// uid and would otherwise inherit every secret the agent holds.
    /// `base` defaults to the process environment (injectable for tests).
    public static func sanitizedEnvironment(
        _ extra: [String: String],
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in base {
            let upper = key.uppercased()
            if upper.hasPrefix("reference_") || upper.hasPrefix("ARC_") || upper.hasPrefix("OPENAI_")
                || upper.hasPrefix("ANTHROPIC_") || upper.hasPrefix("GEMINI_") || upper.hasPrefix("XAI_")
                || upper.hasPrefix("AZURE_") || upper.hasPrefix("AWS_") {
                continue
            }
            result[key] = value
        }
        for (key, value) in extra { result[key] = value }
        return result
    }
}

/// Client-side errors raised before or around a session
/// (mirrors the reference client MCP client error taxonomy).
public enum MCPClientError: Error, CustomStringConvertible {
    case connectionLost
    case shutdown
    case timeout
    case rpc(String)
    /// The configured launch spec is one arc will never run
    /// (``MCPServerLaunchPolicy``).
    case launchRefused(MCPServerLaunchRefusal)

    public var description: String {
        switch self {
        case .connectionLost: return "MCP server connection lost"
        case .shutdown: return "MCP client shut down"
        case .timeout: return "MCP request timed out"
        case .rpc(let msg): return "MCP RPC error: \(msg)"
        case .launchRefused(let refusal): return refusal.description
        }
    }
}