import Foundation

/// A single tool execution recorded during a turn, for UI transparency.
public struct AgentToolStep: Sendable, Codable, Equatable {
    public let name: String
    public let arguments: String
    public let result: String
    public let isError: Bool

    public init(name: String, arguments: String, result: String, isError: Bool = false) {
        self.name = name
        self.arguments = arguments
        self.result = result
        self.isError = isError
    }
}

/// The structured outcome of one agent turn: the final response text, the
/// model's reasoning (if it emitted any), and the tools it executed.
///
/// Carried over the session response stream so the web UI can render
/// tool + reasoning transparency while other surfaces (REST, Telegram) just
/// read ``finalResponse``. It is encoded as a JSON envelope; a plain string
/// on the wire decodes back to a bare ``finalResponse``, so legacy producers
/// keep working.
public struct AgentTurn: Sendable, Codable, Equatable {

    public let finalResponse: String
    public let reasoning: String
    public let toolSteps: [AgentToolStep]

    public init(finalResponse: String, reasoning: String = "", toolSteps: [AgentToolStep] = []) {
        self.finalResponse = finalResponse
        self.reasoning = reasoning
        self.toolSteps = toolSteps
    }

    /// The JSON envelope sent over the response stream.
    public func encoded() -> String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? self.finalResponse
    }

    /// Decode an ``AgentTurn`` envelope from the response stream. A non-envelope
    /// string decodes as a bare ``finalResponse``, so the CLI/other surfaces
    /// that still send plain text are unaffected.
    public static func decodeEnvelope(_ raw: String) -> AgentTurn {
        if let data = raw.data(using: .utf8),
           let turn = try? JSONDecoder().decode(AgentTurn.self, from: data) {
            return turn
        }
        return AgentTurn(finalResponse: raw)
    }
}
