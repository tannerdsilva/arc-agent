import System
import Foundation

/// The `read_file` tool: reads a text file and returns its contents.
///
/// Uses `swift-system`'s ``FileDescriptor`` for all file I/O, avoiding
/// Foundation's higher-level APIs for deterministic, low-level control.
///
/// ## Parameters
/// - `path`: Absolute or relative path to the file.
/// - `offset`: (Optional) 1-based line number to start reading from.
/// - `limit`: (Optional) Maximum number of lines to return.
///
/// ## Returns
/// The file content as a string, with line numbers prefixed.
public enum ReadFileTool {

    /// The ``ToolEntry`` for this tool.
    public static let entry = ToolEntry(
        name: "read_file",
        toolset: "file",
        description: "Read a text file and return its contents with line numbers. "
            + "Use offset and limit for pagination.",
        schema: .object(properties: [
            "path": .string(description: "Path to the file to read"),
            "offset": .integer(description: "1-based line number to start from", default: 1),
            "limit": .integer(description: "Maximum number of lines to return", default: 2000),
        ]),
        handler: { args in
            let path: String = try Self.required(args, key: "path")
            let offset: Int = (args["offset"] as? Int) ?? 1
            let limit: Int = (args["limit"] as? Int) ?? 2000
            return try await Self.readFile(path: path, offset: offset, limit: limit)
        },
        emoji: "📄"
    )

    // MARK: - Handler

    private static func readFile(path: String, offset: Int, limit: Int) async throws -> String {
        let filePath = FilePath(path)

        // Open the file for reading only.
        let fd = try FileDescriptor.open(filePath, .readOnly)
        // Ensure the file descriptor is closed on all paths.
        defer { try? fd.close() }

        // Read the entire file into memory.
        let data = try fd.readAll()

        guard let content = String(data: data, encoding: .utf8) else {
            return "Error: File at '\(path)' is not valid UTF-8 text."
        }

        let lines = content.components(separatedBy: .newlines)
        let startIndex = max(0, offset - 1)
        let endIndex = min(lines.count, startIndex + limit)

        guard startIndex < lines.count else {
            return "Error: Offset \(offset) exceeds file length (\(lines.count) lines)."
        }

        let selectedLines = lines[startIndex..<endIndex]
        let numbered = selectedLines.enumerated().map { (i, line) in
            "\(startIndex + i + 1)|\(line)"
        }

        let totalLines = lines.count
        var result = numbered.joined(separator: "\n")

        // Append truncation hint if we didn't return everything.
        if endIndex < totalLines {
            result += "\n-- Truncated: showing lines \(offset)-\(endIndex) of \(totalLines). "
                + "Use offset=\(endIndex + 1) to continue reading."
        }

        return result
    }

    // MARK: - Helpers

    /// Extract a required parameter from the arguments dictionary.
    private static func required<T>(_ args: [String: Any], key: String) throws -> T {
        guard let value = args[key] as? T else {
            throw ToolError.missingParameter(key)
        }
        return value
    }
}

// MARK: - FileDescriptor Extension

extension FileDescriptor {
    /// Read all remaining data from the file descriptor.
    fileprivate func readAll() throws -> Data {
        var data = Data()
        let chunkSize = 65_536  // 64 KB chunks
        while true {
            var chunk = Data(count: chunkSize)
            let bytesRead = try chunk.withUnsafeMutableBytes { rawBuffer in
                try self.read(into: rawBuffer, retryOnInterrupt: true)
            }
            guard bytesRead > 0 else { break }
            if bytesRead < chunkSize {
                chunk = chunk[..<bytesRead]
            }
            data.append(chunk)
        }
        return data
    }
}

/// Errors that can occur during tool execution.
public enum ToolError: Error, Sendable, CustomStringConvertible {
    /// A required parameter was missing from the arguments dictionary.
    case missingParameter(String)

    public var description: String {
        switch self {
        case .missingParameter(let key):
            return "Missing required parameter: '\(key)'."
        }
    }
}
