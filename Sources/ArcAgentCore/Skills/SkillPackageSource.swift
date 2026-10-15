import Foundation
import SwiftSlash
import AsyncHTTPClient
import NIO

// MARK: - Skill package source resolution
//
// Turns the user-facing bundle argument — a directory path, a `.zip` file, an
// http(s) URL, or a bare bundle name — into a local package *directory* that
// ``SkillPackageInstaller`` can consume. Network and archive handling live
// here so the installer itself stays a pure, testable filesystem operation.

public enum SkillPackageSourceError: Error, Sendable, Equatable, CustomStringConvertible {
    case notFound(String)
    case downloadFailed(String)
    case extractionFailed(String)
    case unsupportedScheme(String)

    public var description: String {
        switch self {
        case .notFound(let what):
            return "Bundle '\(what)' not found. Try a directory path, a .zip, an http(s) URL, or a name in the registry."
        case .downloadFailed(let detail):
            return "Failed to download bundle: \(detail)"
        case .extractionFailed(let detail):
            return "Failed to extract bundle: \(detail)"
        case .unsupportedScheme(let scheme):
            return "Unsupported URL scheme '\(scheme)'. Only http and https are supported."
        }
    }
}

public enum SkillPackageSource {

    /// Resolve a user-supplied bundle reference to a local package directory.
    /// - Parameters:
    ///   - bundle: A directory path, `.zip` path, http(s) URL, or bare name.
    ///   - registry: Directory to search for bare names (default
    ///     `~/.arc/skill-packages`). A bare name `foo` resolves to
    ///     `<registry>/foo/`.
    ///   - downloadDir: Where downloaded/extracted packages are staged
    ///     (defaults to the system temp directory).
    /// - Returns: The local directory containing `manifest.json`.
    public static func resolve(
        bundle: String,
        registry: URL? = nil,
        downloadDir: URL? = nil
    ) async throws -> URL {
        // 1. Bare name against the registry.
        if isBareName(bundle) {
            let reg = registry ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".arc/skill-packages")
            let candidate = reg.appendingPathComponent(bundle)
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("manifest.json").path) {
                return candidate
            }
            return try await resolveUnqualified(bundle, registry: reg, downloadDir: downloadDir)
        }

        // 2. http(s) URL -> download + extract.
        if bundle.hasPrefix("http://") || bundle.hasPrefix("https://") {
            return try await downloadAndExtract(urlString: bundle, downloadDir: downloadDir)
        }

        // 3. Local path.
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: bundle, isDirectory: &isDir) {
            let url = URL(fileURLWithPath: bundle)
            if isDir.boolValue {
                if fm.fileExists(atPath: url.appendingPathComponent("manifest.json").path) {
                    return url
                }
                throw SkillPackageSourceError.extractionFailed("directory has no manifest.json")
            }
            // A file: treat as an archive.
            return try await extractArchive(at: url, downloadDir: downloadDir)
        }

        throw SkillPackageSourceError.notFound(bundle)
    }

    /// A bare name that wasn't in the registry: fall through to a local
    /// directory path of the same name, else report not found.
    private static func resolveUnqualified(
        _ bundle: String,
        registry: URL,
        downloadDir: URL?
    ) async throws -> URL {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: bundle, isDirectory: &isDir) {
            let url = URL(fileURLWithPath: bundle)
            if isDir.boolValue,
               fm.fileExists(atPath: url.appendingPathComponent("manifest.json").path) {
                return url
            }
        }
        // Also accept a bare-name zip sitting in the registry.
        let zipCandidate = registry.appendingPathComponent("\(bundle).zip")
        if fm.fileExists(atPath: zipCandidate.path) {
            return try await extractArchive(at: zipCandidate, downloadDir: downloadDir)
        }
        throw SkillPackageSourceError.notFound(bundle)
    }

    /// True when `bundle` is a plausible bare package name (slug chars only).
    static func isBareName(_ bundle: String) -> Bool {
        guard !bundle.isEmpty, bundle.count <= 64 else { return false }
        let pattern = #"^[a-z0-9][a-z0-9-_]*$"#
        return bundle.range(of: pattern, options: .regularExpression) != nil
    }

    /// Download an http(s) URL to a temp zip and extract it.
    static func downloadAndExtract(urlString: String, downloadDir: URL?) async throws -> URL {
        guard let url = URL(string: urlString) else {
            throw SkillPackageSourceError.downloadFailed("invalid URL")
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw SkillPackageSourceError.unsupportedScheme(url.scheme ?? "")
        }

        let data: Data
        do {
            data = try await fetchData(from: url)
        } catch {
            throw SkillPackageSourceError.downloadFailed(error.localizedDescription)
        }

        let temp = downloadDir ?? FileManager.default.temporaryDirectory
        let zipName = (url.lastPathComponent.isEmpty ? "bundle.zip" : url.lastPathComponent)
        let zipURL = temp.appendingPathComponent("arc-bundle-\(UUID().uuidString)-\(zipName)")
        try data.write(to: zipURL, options: .atomic)
        return try await extractArchive(at: zipURL, downloadDir: downloadDir)
    }

    /// Fetch bytes with a bounded timeout. The client is created per call and
    /// shut down before this returns — a leaked AsyncHTTPClient traps in its
    /// deinit, and a process-wide static client would never be destroyed.
    private static func fetchData(from url: URL) async throws -> Data {
        try await withOneShotHTTPClient { client in
            let request = HTTPClientRequest(url: url.absoluteString)
            let response = try await client.execute(request, timeout: .seconds(60))
            guard response.status == .ok else {
                throw SkillPackageSourceError.downloadFailed("HTTP \(response.status.code)")
            }
            var collected = Data()
            for try await chunk in response.body {
                collected.append(contentsOf: chunk.readableBytesView)
            }
            guard collected.count <= 64 * 1024 * 1024 else {
                throw SkillPackageSourceError.downloadFailed("package exceeds 64 MB limit")
            }
            return collected
        }
    }

    /// Extract a `.zip` archive into a fresh temp directory and return it.
    static func extractArchive(at archiveURL: URL, downloadDir: URL?) async throws -> URL {
        guard archiveURL.pathExtension.lowercased() == "zip" else {
            throw SkillPackageSourceError.extractionFailed("only .zip archives are supported")
        }
        let temp = downloadDir ?? FileManager.default.temporaryDirectory
        let dest = temp.appendingPathComponent("arc-bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        var command: Command
        #if os(macOS)
        command = Command(absolutePath: Path("/usr/bin/ditto"), arguments: ["-x", "-k", archiveURL.path, dest.path])
        #else
        command = Command(absolutePath: Path("/usr/bin/unzip"), arguments: ["-q", archiveURL.path, "-d", dest.path])
        #endif

        let outcome = try await SubprocessRunner.runBytes(command, timeout: 120, captureCap: 2_000_000)
        guard outcome.exitCodeValue == 0 else {
            let err = String(data: outcome.stderr, encoding: .utf8) ?? "unknown error"
            throw SkillPackageSourceError.extractionFailed(err)
        }

        // A zip may contain a single top-level directory wrapping the package
        // (e.g. `swift-code/`), or the package contents directly. Detect and
        // unwrap the wrapping directory if it is the only child.
        return unwrapSingleDirectory(in: dest)
    }

    /// If the extraction produced exactly one directory containing a
    /// manifest.json, return that directory; otherwise return the root.
    static func unwrapSingleDirectory(in root: URL) -> URL {
        let fm = FileManager.default
        let manifest = root.appendingPathComponent("manifest.json")
        if fm.fileExists(atPath: manifest.path) { return root }
        let children = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        if children.count == 1 {
            let child = root.appendingPathComponent(children[0])
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue,
               fm.fileExists(atPath: child.appendingPathComponent("manifest.json").path) {
                return child
            }
        }
        return root
    }
}
