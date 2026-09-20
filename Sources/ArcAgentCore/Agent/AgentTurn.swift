import Foundation

/// A single tool execution recorded during a turn, for UI transparency.
public struct AgentToolStep: Sendable, Codable, Equatable {
    public let name: String
    public let arguments: String
    public let result: String
    public let isError: Bool
    /// how long the tool took to run, in milliseconds.
    public let durationMs: Double?

    public init(name: String, arguments: String, result: String, isError: Bool = false, durationMs: Double? = nil) {
        self.name = name
        self.arguments = arguments
        self.result = result
        self.isError = isError
        self.durationMs = durationMs
    }
}

/// The structured outcome of one agent turn: the final response text, the
/// model's reasoning (if it emitted any), the tools it executed, and a few
/// summary numbers.
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
    public let iterations: Int
    public let promptTokens: Int
    public let completionTokens: Int
    public let totalTokens: Int

    public init(
        finalResponse: String,
        reasoning: String = "",
        toolSteps: [AgentToolStep] = [],
        iterations: Int = 0,
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        totalTokens: Int = 0
    ) {
        self.finalResponse = finalResponse
        self.reasoning = reasoning
        self.toolSteps = toolSteps
        self.iterations = iterations
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
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
