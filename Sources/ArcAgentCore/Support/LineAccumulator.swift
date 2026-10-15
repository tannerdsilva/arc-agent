import Foundation

/// Incremental newline splitter fed by a `FileHandle.readabilityHandler`.
///
/// Single-threaded by contract (one handler per handle, and Foundation runs
/// each handle's handler on its own internal queue) — no locking needed.
final class LineAccumulator: @unchecked Sendable {
    private var pendingLine = Data()
    private let onLine: (String) -> Void

    init(onLine: @escaping (String) -> Void) {
        self.onLine = onLine
    }

    func feed(_ data: Data) {
        pendingLine.append(data)
        while let idx = pendingLine.firstIndex(of: 0x0A) {
            let lineData = pendingLine[..<idx]
            pendingLine.removeSubrange(...idx)
            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: .newlines)
            if !line.isEmpty { onLine(line) }
        }
    }
}