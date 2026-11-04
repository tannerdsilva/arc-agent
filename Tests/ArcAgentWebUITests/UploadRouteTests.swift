import Foundation
import NIOCore
import NIOPosix
import Testing
import WebUI
import WebUIServer

import ArcAgentCore
@testable import ArcWebUI

// MARK: - harness

/// A real `WebUIServer` carrying the two routes the host mounts: the page route
/// that records the token it serves, and the streaming upload route. The tests
/// drive it over the loopback socket — the same path a browser takes — instead
/// of calling the handler as a function, so auth, routing and the wire framing
/// are all in the assertion.
private struct UploadHarness {
    let root: URL
    let tokenStore: UploadTokenStore
    let port: Int
    let server: WebUIServer
    let run: Task<Void, Error>
    let uploaded: UploadRecorder

    /// GET the page and read the render token out of the `webui-config` meta —
    /// the exact value the browser would echo on an upload.
    func pageToken() async throws -> String {
        let page = try await get("/")
        let token = try #require(
            UploadHarness.token(inPage: page),
            "the served page carried no renderToken in its webui-config meta"
        )
        return token
    }

    func get(_ path: String) async throws -> String {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        #expect(status == 200, "GET \(path) answered \(status)")
        return String(decoding: data, as: UTF8.self)
    }

    /// POST the upload route. `token == nil` omits the header entirely (the
    /// no-credential case); every other field is always sent.
    func upload(
        path: String,
        name: String,
        token: String?,
        origin: String?,
        body: [UInt8]
    ) async throws -> (status: Int, json: [String: Any]) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(WorkspaceUpload.routePath)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(origin ?? "http://127.0.0.1:\(port)", forHTTPHeaderField: "Origin")
        request.setValue(path, forHTTPHeaderField: "X-Upload-Path")
        request.setValue(name, forHTTPHeaderField: "X-Upload-Name")
        if let token { request.setValue(token, forHTTPHeaderField: "X-Render-Token") }
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body)
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, json)
    }

    /// Every entry in the workspace root, hidden ones included — a `.part`
    /// file must be visible here, or its cleanup cannot be asserted.
    func rootEntries() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
    }

    func partEntries() -> [String] {
        rootEntries().filter { $0.hasPrefix(".") && $0.hasSuffix(".part") }
    }

    /// Stop the server and prove the listener is gone: a suite that leaks a
    /// listening socket poisons every later run on the machine.
    func stop() async {
        await server.stop()
        run.cancel()
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        _ = await waitUntilAsync(timeout: 5) {
            do {
                _ = try await URLSession(configuration: .ephemeral).data(from: url)
                return false
            } catch {
                return true
            }
        }
    }

    static func token(inPage page: String) -> String? {
        // the meta value is attribute-escaped: `{&quot;renderToken&quot;:&quot;…&quot;}`
        let marker = "renderToken&quot;:&quot;"
        guard let start = page.range(of: marker) else { return nil }
        let rest = page[start.upperBound...]
        guard let end = rest.range(of: "&quot;") else { return nil }
        let value = String(rest[..<end.lowerBound])
        return value.isEmpty ? nil : value
    }
}

/// counts `onUploaded` calls — the tree-cache refresh hook.
private actor UploadRecorder {
    private(set) var count = 0
    func bump() { count += 1 }
}

/// boot the harness on a free port, run `body`, and always stop the server.
private func withUploadServer(
    limit: Int = 1 << 20,
    capacity: Int = UploadTokenStore.defaultCapacity,
    _ body: (UploadHarness) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("arc-upload-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let tokens = UploadTokenStore(capacity: capacity)
    let recorder = UploadRecorder()
    let router = Router {
        WorkspaceUpload.pageRoute("/", tokens: tokens) { _, token in
            AppShell.makeDocument(
                sheetURL: "/ui/style.css",
                overlayURL: "/ui/init.js",
                renderToken: token
            )(
                UnsafeMarkup.trusted("<p id=\"upload-probe\">upload harness</p>"),
                "data-scheme=\"poseidon\" data-theme=\"dark\""
            )
        }
        WorkspaceUpload.uploadRoute(
            root: { root },
            tokenStore: tokens,
            limit: limit,
            onUploaded: { await recorder.bump() }
        )
    }

    var harness: UploadHarness?
    var lastError: Error?
    for _ in 0..<8 {
        let port = Int.random(in: 20000..<40000)
        let server = WebUIServer(
            router: router,
            config: WebUIServerConfig(host: "127.0.0.1", port: port)
        )
        let run = Task { try await server.start() }
        if await waitUntilServing(port: port, timeout: 3) {
            harness = UploadHarness(
                root: root, tokenStore: tokens, port: port, server: server, run: run, uploaded: recorder
            )
            break
        }
        await server.stop()
        run.cancel()
        lastError = UploadHarnessError.couldNotBind
    }
    guard let harness else { throw lastError ?? UploadHarnessError.couldNotBind }

    do {
        try await body(harness)
    } catch {
        await harness.stop()
        throw error
    }
    await harness.stop()
}

private enum UploadHarnessError: Error {
    case couldNotBind
    case timedOut
}

private func waitUntilServing(port: Int, timeout: TimeInterval) async -> Bool {
    let url = URL(string: "http://127.0.0.1:\(port)/")!
    return await waitUntilAsync(timeout: timeout) {
        (try? await URLSession(configuration: .ephemeral).data(from: url)) != nil
    }
}

/// poll an async condition until it holds or the deadline passes.
private func waitUntilAsync(timeout: TimeInterval, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(40))
    }
    return await condition()
}

// MARK: - fixtures

private func patternBytes(_ count: Int) -> [UInt8] {
    (0..<count).map { UInt8($0 % 251) }
}

private func readFile(_ url: URL) -> Data? {
    try? Data(contentsOf: url)
}

// MARK: - tests

@Suite("Workspace upload route", .serialized)
struct UploadRouteTests {

    @Test("an upload with no render token is refused 403 and writes nothing")
    func uploadWithoutARenderTokenIsRefusedAndWritesNothing() async throws {
        try await withUploadServer { harness in
            let (status, json) = try await harness.upload(
                path: "no-token.txt",
                name: "no-token.txt",
                token: nil,
                origin: nil,
                body: patternBytes(4096)
            )
            #expect(status == 403, "a tokenless upload answered \(status)")
            #expect(json["ok"] as? Bool == false)
            #expect(harness.rootEntries().isEmpty, "a refused upload wrote \(harness.rootEntries())")
        }
    }

    @Test("a cross-origin upload is refused 403 even with a valid token, and writes nothing")
    func crossOriginUploadIsRefusedEvenWithAValidToken() async throws {
        try await withUploadServer { harness in
            let token = try await harness.pageToken()
            let (status, json) = try await harness.upload(
                path: "cross-origin.txt",
                name: "cross-origin.txt",
                token: token,
                origin: "http://evil.example",
                body: patternBytes(4096)
            )
            #expect(status == 403, "a cross-origin upload answered \(status)")
            #expect(json["ok"] as? Bool == false)
            #expect(harness.rootEntries().isEmpty, "a refused upload wrote \(harness.rootEntries())")
        }
    }

    @Test("an unknown or stale render token is refused 403")
    func unknownRenderTokenIsRefused() async throws {
        try await withUploadServer { harness in
            let (status, json) = try await harness.upload(
                path: "stale.txt",
                name: "stale.txt",
                token: "never-served-by-this-host",
                origin: nil,
                body: patternBytes(1024)
            )
            #expect(status == 403, "an unknown token answered \(status)")
            #expect(json["ok"] as? Bool == false)
            #expect(harness.rootEntries().isEmpty, "a refused upload wrote \(harness.rootEntries())")
        }
    }

    @Test("a valid upload lands the exact bytes and answers ok/path/bytes")
    func validUploadLandsTheExactBytes() async throws {
        try await withUploadServer { harness in
            let token = try await harness.pageToken()
            let body = patternBytes(300_000)
            let (status, json) = try await harness.upload(
                path: "notes/big.bin",
                name: "big.bin",
                token: token,
                origin: nil,
                body: body
            )
            #expect(status == 200, "a valid upload answered \(status): \(json)")
            #expect(json["ok"] as? Bool == true)
            #expect(json["path"] as? String == "notes/big.bin")
            #expect(json["bytes"] as? Int == body.count)

            let destination = harness.root.appendingPathComponent("notes/big.bin")
            let written = try #require(readFile(destination), "the uploaded file is not on disk")
            #expect(written.count == body.count, "wrote \(written.count) bytes, sent \(body.count)")
            #expect(
                SHA256Digest.hex(written) == SHA256Digest.hex(Data(body)),
                "the file's sha256 does not match the body that was sent"
            )
            // the `.part` sibling is gone: the file appeared by rename, not by
            // growing under its final name.
            let notesDir = harness.root.appendingPathComponent("notes")
            let siblings = (try? FileManager.default.contentsOfDirectory(atPath: notesDir.path)) ?? []
            #expect(!siblings.contains { $0.hasSuffix(".part") }, "a .part survived: \(siblings)")
            let uploads = await harness.uploaded.count
            #expect(uploads == 1, "the tree-cache refresh hook ran \(uploads) times")
        }
    }

    @Test("a traversal path is refused and nothing is written outside the root")
    func traversalPathIsRefusedAndWritesNothingOutsideTheRoot() async throws {
        try await withUploadServer { harness in
            let token = try await harness.pageToken()
            let escape = harness.root.deletingLastPathComponent().appendingPathComponent("escape.txt")
            try? FileManager.default.removeItem(at: escape)
            for path in ["../escape.txt", "notes/../../escape.txt", "/etc/escape.txt", "."] {
                let (status, json) = try await harness.upload(
                    path: path,
                    name: "escape.txt",
                    token: token,
                    origin: nil,
                    body: patternBytes(128)
                )
                #expect(status == 400 || status == 403, "\(path) answered \(status)")
                #expect(json["ok"] as? Bool == false)
            }
            // the name is a filename, never a path — a traversal in the name is
            // refused even when the path header is clean.
            for name in ["..", "../escape.txt", "sub/escape.txt", "back\\slash.txt", ""] {
                let (status, json) = try await harness.upload(
                    path: "clean.txt",
                    name: name,
                    token: token,
                    origin: nil,
                    body: patternBytes(128)
                )
                #expect(status == 400, "name '\(name)' answered \(status)")
                #expect(json["ok"] as? Bool == false)
            }
            #expect(!FileManager.default.fileExists(atPath: escape.path), "a traversal upload escaped the root")
            #expect(harness.rootEntries().isEmpty, "a refused upload wrote \(harness.rootEntries())")
        }
    }

    @Test("a client that disconnects mid-body leaves no .part and no destination file")
    func disconnectMidBodyLeavesNoPartialFile() async throws {
        try await withUploadServer { harness in
            let token = try await harness.pageToken()
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let channel: Channel
            do {
                channel = try await ClientBootstrap(group: group)
                    .connectTimeout(.seconds(10))
                    .connect(host: "127.0.0.1", port: harness.port)
                    .get()
            } catch {
                try await group.shutdownGracefully()
                throw error
            }

            let declared = 262_144
            let head = [
                "POST \(WorkspaceUpload.routePath) HTTP/1.1",
                "Host: 127.0.0.1:\(harness.port)",
                "Origin: http://127.0.0.1:\(harness.port)",
                "X-Render-Token: \(token)",
                "X-Upload-Path: partial.bin",
                "X-Upload-Name: partial.bin",
                "Content-Type: application/octet-stream",
                "Content-Length: \(declared)",
                "",
                "",
            ].joined(separator: "\r\n")
            do {
                var buffer = channel.allocator.buffer(capacity: head.utf8.count + 8192)
                buffer.writeString(head)
                buffer.writeBytes(patternBytes(8192))
                try await channel.writeAndFlush(buffer).get()

                // the writer must have started: a `.part` exists before the
                // client leaves. without this the cleanup assertion below could
                // pass because nothing ever began.
                let sawPart = await waitUntilAsync(timeout: 5) { !harness.partEntries().isEmpty }
                #expect(sawPart, "no .part appeared, so the disconnect never interrupted a write")

                try await channel.close().get()
                try await group.shutdownGracefully()

                let partGone = await waitUntilAsync(timeout: 10) { harness.partEntries().isEmpty }
                #expect(partGone, "the .part survived the disconnect: \(harness.partEntries())")
                #expect(
                    !FileManager.default.fileExists(atPath: harness.root.appendingPathComponent("partial.bin").path),
                    "a truncated upload was renamed into place"
                )
            } catch {
                try? await channel.close().get()
                try? await group.shutdownGracefully()
                throw error
            }
        }
    }

    @Test("the token store keeps a bounded window and drops the oldest token")
    func tokenStoreEvictsTheOldestToken() async throws {
        let store = UploadTokenStore(capacity: 3)
        await store.record("")
        #expect(await store.count == 0, "an empty token was recorded")
        for token in ["a", "b", "c"] { await store.record(token) }
        #expect(await store.count == 3)
        #expect(await store.contains("a"))
        // a fourth page load evicts the first: a tab older than the window is
        // refused until it reloads.
        await store.record("d")
        #expect(await store.count == 3)
        #expect((await store.contains("a")) == false, "the oldest token was not evicted")
        #expect(await store.contains("d"))
        // re-serving a live token must not consume a second slot.
        await store.record("d")
        #expect(await store.count == 3)
    }

    @Test("the served page carries the token it recorded")
    func pageCarriesTheTokenItRecorded() async throws {
        try await withUploadServer { harness in
            let page = try await harness.get("/")
            let token = try #require(UploadHarness.token(inPage: page), "no renderToken in the page meta")
            #expect(!token.isEmpty)
            #expect(await harness.tokenStore.contains(token), "the page's token was not recorded by the page route")
            #expect(
                page.contains("&quot;renderToken&quot;:&quot;\(token)&quot;"),
                "the page did not publish its token in the webui-config meta"
            )
            // the token reaches the page through `makeDocument`, and only when
            // it is handed one — a page rendered without a token must not
            // carry an empty credential the client could echo back.
            let markup = UnsafeMarkup.trusted("<p>probe</p>")
            let attrs = "data-scheme=\"poseidon\" data-theme=\"dark\""
            let without = AppShell.makeDocument(sheetURL: "/ui/style.css", overlayURL: "/ui/init.js")(markup, attrs)
            let with = AppShell.makeDocument(
                sheetURL: "/ui/style.css", overlayURL: "/ui/init.js", renderToken: token
            )(markup, attrs)
            #expect(
                !without.markup.html.contains(token),
                "a page rendered without a token must not carry one"
            )
            #expect(
                with.markup.html.contains(token),
                "a page rendered with a token must publish it"
            )
        }
    }

    @Test("a full disk refuses with the free-space constraint named, not the configured cap")
    func budgetRefusesOnAFullDiskAndNamesTheConstraint() throws {
        let cap = 8 * 1024 * 1024 * 1024
        let reserve = WorkspaceUpload.diskReserve
        // a full disk: zero budget, and the refusal names the disk.
        let full = WorkspaceUpload.budget(freeBytes: reserve / 2, cap: cap)
        #expect(full.bytes == 0)
        #expect(full.constraint.contains("free disk space"))
        let empty = WorkspaceUpload.budget(freeBytes: 0, cap: cap)
        #expect(empty.bytes == 0)
        // a negative budget is clamped, never handed to the writer.
        let negative = WorkspaceUpload.budget(freeBytes: -1, cap: cap)
        #expect(negative.bytes == 0)
        // free space below the cap is the constraint.
        let tight = WorkspaceUpload.budget(freeBytes: reserve + 5 * 1024 * 1024, cap: cap)
        #expect(tight.bytes == 5 * 1024 * 1024)
        #expect(tight.constraint.contains("free disk space"))
        // plenty of space: the configured cap wins.
        let ample = WorkspaceUpload.budget(freeBytes: Int64(cap) * 4, cap: cap)
        #expect(ample.bytes == cap)
        #expect(ample.constraint.contains("configured"))
        // unreadable free space falls back to the cap rather than to zero.
        let unknown = WorkspaceUpload.budget(freeBytes: nil, cap: cap)
        #expect(unknown.bytes == cap)
    }
}
