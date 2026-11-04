import Foundation
import NIOHTTP1
import WebUICore
import WebUI
import WebUIServer

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The render tokens this host has served, so an upload can prove it came from
/// a page this server rendered.
///
/// The framework mints a token per request (`WebUIServer.swift`'s page path), so
/// a POST cannot re-derive the token the page holds — the host has to remember
/// what it served. The set is bounded: a daemon runs for weeks and a page load
/// mints a token, so an unbounded set would be a slow leak. The oldest token is
/// dropped first, which means a browser tab older than the last `capacity`
/// page loads is refused on upload (`403`) until it reloads. That is the
/// intended trade: a token is a liveness hint, not a durable credential.
actor UploadTokenStore {

    /// How many of the most recently served tokens stay valid.
    static let defaultCapacity = 256

    private let capacity: Int
    /// insertion order, oldest first — the eviction queue.
    private var order: [String] = []
    private var members: Set<String> = []

    init(capacity: Int = UploadTokenStore.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    /// Remember a token the page route just served.
    ///
    /// An empty token is not recorded: the framework's mint can fail (no
    /// platform entropy), and a page that carries no token must not make ""
    /// a credential.
    func record(_ token: String) {
        guard !token.isEmpty else { return }
        // a re-served token keeps its original position; only the set matters.
        if members.insert(token).inserted {
            order.append(token)
        }
        while order.count > capacity {
            members.remove(order.removeFirst())
        }
    }

    /// True when `token` is one this host served and has not evicted.
    func contains(_ token: String) -> Bool {
        !token.isEmpty && members.contains(token)
    }

    /// How many tokens are currently valid (tests and logs).
    var count: Int { members.count }
}

/// `POST /api/upload` — a workspace file arrives as a streamed body, lands on
/// disk under the panel's workspace root, and only appears under its real name
/// once the whole body arrived.
///
/// Why a builder: the route is auth + path rules + a writer, and none of that
/// needs arc's daemon to be observed. A test mounts the same two routes the
/// host mounts (`pageRoute` and `uploadRoute`) on its own `WebUIServer` with a
/// temporary workspace, and drives real requests.
enum WorkspaceUpload {

    /// The route the client posts to.
    static let routePath = "/api/upload"

    /// Arc's configured ceiling for one upload. The framework counts the body
    /// against this; the free-space budget below can only lower it.
    static let configuredCap = 8 * 1024 * 1024 * 1024

    /// Kept free on the upload volume — the daemon still has to write sessions,
    /// logs and the rest of the workspace after a multi-GB file lands.
    static let diskReserve: Int64 = 2 * 1024 * 1024 * 1024

    // MARK: - budget

    /// The byte budget for one upload, and the sentence that names whatever set
    /// it — the configured cap or the disk itself. A refusal that says only
    /// "too large" hides the fact that the SD card is full.
    struct Budget {
        let bytes: Int
        let constraint: String
    }

    /// Pure budget math, so the full-disk branches are testable without a full
    /// disk. `freeBytes == nil` means the filesystem would not answer.
    static func budget(freeBytes: Int64?, cap: Int) -> Budget {
        guard let freeBytes else {
            return Budget(
                bytes: max(0, cap),
                constraint: "the configured \(byteCount(Int64(cap))) upload cap (free space could not be read)"
            )
        }
        let available = freeBytes - diskReserve
        guard available > 0 else {
            return Budget(
                bytes: 0,
                constraint: "free disk space — \(byteCount(max(0, freeBytes))) available, \(byteCount(diskReserve)) kept in reserve"
            )
        }
        guard available < Int64(cap) else {
            return Budget(bytes: cap, constraint: "the configured \(byteCount(Int64(cap))) upload cap")
        }
        return Budget(
            bytes: Int(available),
            constraint: "free disk space — \(byteCount(max(0, freeBytes))) available, \(byteCount(diskReserve)) kept in reserve"
        )
    }

    /// The budget for the volume that holds `root`, read at request time.
    static func budget(at root: URL, cap: Int = configuredCap) -> Budget {
        let free = (try? FileManager.default.attributesOfFileSystem(forPath: root.path))?[.systemFreeSize] as? NSNumber
        return budget(freeBytes: free?.int64Value, cap: cap)
    }

    private static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - routes

    /// A page route that remembers the render token it handed the page, and
    /// gives the document builder that token so the page can echo it back.
    ///
    /// Recording happens for every page response, including the `?s=` deep
    /// link and the `/index.html` alias: whichever page the browser holds is
    /// the one that may upload.
    static func pageRoute(
        _ pattern: PathPattern,
        tokens: UploadTokenStore,
        provider: @escaping @Sendable (String?, String) async -> WebUI.HTMLDocument
    ) -> Route {
        Route.page(pattern) { request in
            let token = request.renderToken.value
            await tokens.record(token)
            return await provider(request.query["s"], token)
        }
    }

    /// The streaming upload route.
    ///
    /// - parameters:
    ///   - root: resolves the destination workspace root at request time — the
    ///     active chat changes while the daemon runs, so a root captured at
    ///     registration would write into the wrong folder.
    ///   - tokenStore: the tokens this host has served.
    ///   - limit: the framework's counted ceiling for the body. The handler's
    ///     free-space budget can be smaller and is checked as bytes arrive.
    ///   - onUploaded: called after a successful rename (arc clears its
    ///     workspace tree cache here so the file appears on the next render).
    static func uploadRoute(
        root: @escaping @Sendable () async -> URL,
        tokenStore: UploadTokenStore,
        limit: Int,
        onUploaded: @escaping @Sendable () async -> Void = {}
    ) -> Route {
        Route.upload(PathPattern(routePath), limit: limit) { head, body in
            // 1. auth before a single body byte is read: a refused request
            //    writes nothing, and never pays for the upload it asked for.
            guard let token = head.headers.first(name: "X-Render-Token"),
                  await tokenStore.contains(token)
            else {
                return json(403, ["ok": false, "error": "upload refused: missing or unknown render token"])
            }
            // same-origin only. a browser always sends `Origin` on a cross-origin
            // POST; a request with none at all is refused rather than trusted.
            // the expected origin is this server's own `Host` — the address the
            // browser used to reach the page it is uploading from.
            guard let origin = head.headers.first(name: "Origin"),
                  let host = head.headers.first(name: "Host"),
                  !origin.isEmpty,
                  origin == "http://\(host)"
            else {
                return json(403, ["ok": false, "error": "upload refused: cross-origin request"])
            }

            // 2. destination rules. The path is the only thing that names the
            //    destination; the name is a filename, never a path.
            guard let relPath = head.headers.first(name: "X-Upload-Path"),
                  WorkspaceRules.isSafeRelativePath(relPath),
                  !relPath.hasSuffix("/")
            else {
                return json(400, ["ok": false, "error": "upload refused: invalid path"])
            }
            guard let name = head.headers.first(name: "X-Upload-Name"),
                  isSafeFileName(name)
            else {
                return json(400, ["ok": false, "error": "upload refused: invalid file name"])
            }

            let rootURL = await root().standardizedFileURL
            let destination = rootURL.appendingPathComponent(relPath).standardizedFileURL
            // "." standardizes to the root itself, which is a directory: never a
            // file target, and never a rename destination.
            guard destination.path != rootURL.path, isContained(destination, in: rootURL) else {
                return json(400, ["ok": false, "error": "upload refused: invalid path"])
            }

            // 3. the budget at this moment: the disk can fill between requests.
            let budget = budget(at: rootURL, cap: limit)
            guard budget.bytes > 0 else {
                return json(413, ["ok": false, "error": "upload refused: \(budget.constraint)"])
            }
            if let declared = head.contentLength, declared > budget.bytes {
                return json(413, ["ok": false, "error": "upload refused: \(declared) bytes exceeds \(budget.constraint)"])
            }

            // 4. write to a sibling `.part` file and rename only on success, so
            //    a partial write never looks like a finished file.
            let fileManager = FileManager.default
            let directory = destination.deletingLastPathComponent()
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return json(500, ["ok": false, "error": "upload failed: could not create \(directory.lastPathComponent)"])
            }
            let part = directory.appendingPathComponent(".\(name).part")
            // a `.part` left by a crashed daemon is not a resume point — the
            // body starts at zero, so the file must too.
            try? fileManager.removeItem(at: part)
            guard fileManager.createFile(atPath: part.path, contents: nil) else {
                return json(500, ["ok": false, "error": "upload failed: could not create \(part.lastPathComponent)"])
            }
            let handle: FileHandle
            do {
                handle = try FileHandle(forWritingTo: part)
            } catch {
                try? fileManager.removeItem(at: part)
                return json(500, ["ok": false, "error": "upload failed: could not open \(part.lastPathComponent)"])
            }

            var bytes = 0
            var closed = false
            do {
                for try await chunk in body {
                    // a cancelled request (shutdown, or a handler upstream giving
                    // up) stops the write at the next chunk boundary.
                    if Task.isCancelled { throw CancellationError() }
                    // the free-space budget, applied as bytes arrive: a chunked
                    // body declares no length, so the count is the only guard.
                    guard bytes + chunk.count <= budget.bytes else {
                        try? handle.close()
                        closed = true
                        try? fileManager.removeItem(at: part)
                        return json(413, ["ok": false, "error": "upload refused at \(bytes) bytes: \(budget.constraint)"])
                    }
                    try handle.write(contentsOf: Data(chunk))
                    bytes += chunk.count
                }
                try handle.synchronize()
                try handle.close()
                closed = true
            } catch {
                // any failure — a client disconnect, an over-limit cut, a write
                // error — leaves no `.part` behind. The error is rethrown so the
                // framework answers 413 for its own overrun and logs the rest.
                if !closed { try? handle.close() }
                try? fileManager.removeItem(at: part)
                throw error
            }

            do {
                try rename(part, onto: destination)
            } catch {
                try? fileManager.removeItem(at: part)
                return json(500, ["ok": false, "error": "upload failed: could not place \(relPath)"])
            }
            await onUploaded()
            return json(200, ["ok": true, "path": relPath, "bytes": bytes])
        }
    }

    // MARK: - path rules

    /// A file name is one path component: no separators, no `.`/`..`, no
    /// control characters. The name is never appended to the root — the
    /// `X-Upload-Path` header owns the destination — but it names the `.part`
    /// sibling, so it still has to be a plain file name.
    static func isSafeFileName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        guard !name.contains("/"), !name.contains("\\") else { return false }
        return !name.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// True when `url` is `root` or below it, with symlinked ancestors resolved
    /// (`..` is already gone via `standardizedFileURL`; a symlinked workspace
    /// subfolder is not). The lexical check is what `isSafeRelativePath`
    /// promises; this is the filesystem's second opinion.
    static func isContained(_ url: URL, in root: URL) -> Bool {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        if target == base { return true }
        return target.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    // MARK: - filesystem

    /// `rename(2)`: atomic, and it replaces an existing destination in one step,
    /// so a reader never sees a half-written file under the real name.
    private static func rename(_ part: URL, onto destination: URL) throws {
        #if canImport(Darwin)
        let status = Darwin.rename(part.path, destination.path)
        #else
        let status = Glibc.rename(part.path, destination.path)
        #endif
        if status != 0 {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw POSIXError(code)
        }
    }

    // MARK: - responses

    private static func json(_ status: Int, _ object: [String: Any]) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("{\"ok\":false}".utf8)
        return HTTPResponse(
            status: HTTPStatus(status),
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: .bytes([UInt8](body), contentType: "application/json; charset=utf-8")
        )
    }
}
