import System
import Foundation

/// The `write_file` tool: writes content to a file, overwriting any existing content.
///
/// Uses `swift-system`'s ``FileDescriptor`` for all file I/O, ensuring
/// deterministic, low-level control over file creation and writing.
///
/// ## Parameters
/// - `path`: Absolute or relative path to the file.
/// - `content`: The complete content to write (overwrites existing file).
///
/// ## Returns
/// A confirmation message with the path and byte count.
public enum WriteFileTool {

    /// The ``ToolEntry`` for this tool.
    public static let entry = ToolEntry(
        name: "write_file",
        toolset: "file",
        description: "Write content to a file, completely replacing existing content. "
            + "Creates parent directories automatically.",
        schema: .object(properties: [
            "path": .string(description: "Path to the file to write"),
            "content": .string(description: "Complete content to write to the file"),
        ], required: ["path", "content"]),
        handler: { args in
            let path: String = try Self.required(args, key: "path")
            let content: String = try Self.required(args, key: "content")
            return try await Self.writeFile(path: path, content: content)
        },
        emoji: "✏️"
    )

    // MARK: - Handler

    private static func writeFile(path: String, content: String) async throws -> String {
        // Expand leading "~" (e.g. "~/Desktop/hello.txt") so models can use
        // home-relative paths without knowing the absolute home directory.
        let expanded = (path as NSString).expandingTildeInPath
        let filePath = FilePath(expanded)

        // Ensure the parent directory exists.
        try createParentDirectory(for: filePath)

        // Convert the string to data.
        guard let data = content.data(using: .utf8) else {
            return "Error: Could not encode content as UTF-8."
        }

        // Open the file: create if it doesn't exist, truncate if it does.
        let fd = try FileDescriptor.open(
            filePath,
            .writeOnly,
            options: [.create, .truncate],
            permissions: .ownerReadWrite
        )
        defer { try? fd.close() }

        // Write all data.
        try data.withUnsafeBytes { rawBuffer in
            var totalWritten = 0
            while totalWritten < data.count {
                let remaining = UnsafeRawBufferPointer(
                    start: rawBuffer.baseAddress!.advanced(by: totalWritten),
                    count: data.count - totalWritten
                )
                let written = try fd.write(remaining)
                totalWritten += written
            }
        }

        let byteCount = data.count
        return "Successfully wrote \(byteCount) byte(s) to '\(expanded)'."
    }

    // MARK: - Helpers

    /// Create the parent directory of the given file path if it doesn't exist.
    private static func createParentDirectory(for path: FilePath) throws {
        let parent = path.removingLastComponent()
        // removingLastComponent() returns the root for top-level paths
        // or the current path if there's no parent.
        let parentStr = parent.string
        guard !parentStr.isEmpty, parentStr != path.string else { return }

        try FileManager.default.createDirectory(
            atPath: parentStr,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    /// Extract a required parameter from the arguments dictionary.
    private static func required<T>(_ args: [String: Any], key: String) throws -> T {
        guard let value = args[key] as? T else {
            throw ToolError.missingParameter(key)
        }
        return value
    }
}
