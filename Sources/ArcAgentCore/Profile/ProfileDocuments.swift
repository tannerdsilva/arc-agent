import ArcToolKit
import Foundation

// MARK: - ProfileDocuments
//
// The only type that touches a profile's documents on disk. It is constructed
// from exactly one resolved root plus the grant that governs it, and the root
// is `private let`: a `ProfileDocuments` value cannot be re-pointed after
// construction, so "write another profile's MEMORY.md" is not a policy
// violation to detect — it is a value that cannot be built.
//
// The root is the calling profile's directory
// (`~/.arc/profiles/<name>`), resolved once by
// `ArcAgentCore.buildRegistry(context:…)` from `ToolContext.profile`. It is the
// same directory the CLI hands `FileMemoryProvider`, which is what makes the
// `memory` tool and `profile_edit` address one document (GROUNDZERO slice 4).

/// A profile's documents, bound to one root.
public struct ProfileDocuments: Sendable {

    /// Why a document operation failed.
    public enum Failure: Error, Sendable, CustomStringConvertible {
        /// The grant does not permit this write.
        case refused(String)
        /// The document exists but could not be decoded.
        case unreadable(path: String)
        /// The write itself failed.
        case writeFailed(path: String, reason: String)

        public var description: String {
            switch self {
            case .refused(let reason):
                return reason
            case .unreadable(let path):
                return "could not read " + path
            case .writeFailed(let path, let reason):
                return "could not write " + path + ": " + reason
            }
        }
    }

    /// The one directory these documents live in. `let`, private, never
    /// derived from caller input after construction.
    private let root: URL

    /// The authority this document set is exercised under.
    public let grant: ToolGrant

    /// Bind a document set to `root`.
    public init(root: URL, grant: ToolGrant) {
        self.root = root.standardizedFileURL
        self.grant = grant
    }

    /// The profile these documents belong to (from the grant).
    public var profile: ProfileName { grant.profile }

    /// The bound root, as a path.
    public var rootPath: String { root.path }

    /// The URL of one document under the bound root.
    public func url(for file: ProfileFile) -> URL {
        root.appendingPathComponent(file.fileName)
    }

    /// The canonical path of one document under the bound root.
    public func path(for file: ProfileFile) -> String {
        Self.canonical(url(for: file).path)
    }

    /// Read `file`.
    ///
    /// Reads are never gated — the lockdown has always allowed the agent to
    /// read what it may not write. A missing document reads as the empty
    /// string so callers can keep saying "no content yet".
    public func read(_ file: ProfileFile) throws -> String {
        let location = path(for: file)
        guard FileManager.default.fileExists(atPath: location) else { return "" }
        guard let content = try? String(contentsOfFile: location, encoding: .utf8) else {
            throw Failure.unreadable(path: location)
        }
        return content
    }

    /// Write `file`.
    ///
    /// The grant is enforced here as well as in the tool body: a caller that
    /// forgets to ask still cannot write a locked document through this type.
    public func write(_ file: ProfileFile, _ content: String) throws {
        if let refusal = grant.refusal(for: file) {
            throw Failure.refused(refusal)
        }
        let location = url(for: file)
        do {
            try FileManager.default.createDirectory(
                at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: location, atomically: true, encoding: .utf8)
        } catch {
            throw Failure.writeFailed(
                path: location.path, reason: error.localizedDescription)
        }
    }

    /// Whether `path` is one of *these* documents.
    ///
    /// Root-scoped: another profile's `MEMORY.md` is not a member, even though
    /// it has the same file name. Symlinked roots (`/var` → `/private/var`)
    /// compare equal because both sides are canonicalized the same way.
    public func contains(path: String) -> Bool {
        let candidate = Self.canonical(path)
        return ProfileFile.allCases.contains { self.path(for: $0) == candidate }
    }

    /// The document `path` names, when it is one of these documents.
    public func file(at path: String) -> ProfileFile? {
        guard contains(path: path) else { return nil }
        return ProfileFile.at(path: path)
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

extension ProfileDocuments.Failure: LocalizedError {
    public var errorDescription: String? { description }
}
