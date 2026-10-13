import Foundation
import Logging
import NIOConcurrencyHelpers

/// A single captured log line.
struct LogLine: Sendable, Equatable {
    let seq: Int
    let time: Date
    let level: Logger.Level
    let text: String
}

/// Thread-safe ring buffer for in-app log lines.
///
/// `swift-log` calls its handlers synchronously from arbitrary threads, so a
/// plain actor cannot back a `LogHandler`. This is the single hand-rolled lock
/// in the web UI: it only guards the bounded log ring, and the read side never
/// holds it across an async hop.
final class LogCollector: @unchecked Sendable {
    static let shared = LogCollector()

    private let lock = NIOLock()
    private var lines: [LogLine] = []
    private var maxLines = 2000
    private var seqCounter = 0
    private var deliveredSeq = 0

    private init() {}

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return lines.count
    }

    func append(level: Logger.Level, text: String) {
        lock.lock(); defer { lock.unlock() }
        seqCounter += 1
        lines.append(LogLine(seq: seqCounter, time: Date(), level: level, text: text))
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        lines.removeAll()
        deliveredSeq = seqCounter
    }

    func snapshot() -> [LogLine] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }

    /// Lines appended since the last call (for live streaming to the UI).
    func drainNew() -> [LogLine] {
        lock.lock(); defer { lock.unlock() }
        guard let last = lines.last else { return [] }
        if deliveredSeq >= last.seq { return [] }
        let new = lines.filter { $0.seq > deliveredSeq }
        deliveredSeq = last.seq
        return new
    }
}

/// A `LogHandler` that routes every line into the in-app ring buffer instead
/// of stdout, so logs stop appearing in the terminal at the bottom of the
/// screen and instead surface inside the web UI's Logs section.
struct WebUILogHandler: LogHandler {
    var logLevel: Logger.Level = .info
    var metadata: Logger.Metadata = [:]
    let label: String

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        var text = event.message.description
        if let metadata = event.metadata, !metadata.isEmpty {
            let meta = metadata.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
            text += " \(meta)"
        }
        // `source` is the logger's subsystem label (e.g. arc_agent_webui).
        LogCollector.shared.append(level: event.level, text: "[\(event.source)] \(text)")
    }
}
