import Foundation
import Testing
@testable import ArcAgentCore

// MARK: - Deliverable mode (reference `features/deliverable-mode.md`)

@Suite("Deliverable mode")
struct DeliverableTests {

    @Test("paths are extracted and stripped, fences protected")
    func extraction() {
        let text = "Here is the report:\n/tmp/reports/q3.pdf\nand the data /Users/brockwyma/out.csv.\n```\n/tmp/code/not-deliverable.py\n```\ninline `/etc/hosts` stays."
        let (clean, paths) = DeliverableExtractor.extract(text)
        #expect(paths.contains("/tmp/reports/q3.pdf"))
        #expect(paths.contains("/Users/brockwyma/out.csv"))
        #expect(!paths.contains("/tmp/code/not-deliverable.py"))
        #expect(!paths.contains("/etc/hosts"))
        #expect(!clean.contains("/tmp/reports/q3.pdf"))
        #expect(clean.contains("not-deliverable.py"))
    }

    @Test("missing files become notes, existing files get attached")
    func plan() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("deliverable-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let ok = tmp.appendingPathComponent("ok.txt")
        try "hello deliverable".write(to: ok, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let (files, notes) = DeliveryManager.makeDeliverablePlan(
            paths: [ok.path, "/tmp/does-not-exist-\(UUID().uuidString).pdf"],
            platform: "telegram"
        )
        #expect(files.count == 1)
        #expect(files[0].localPath == ok.path)
        #expect(files[0].filename == "ok.txt")
        #expect(notes.count == 1)
        #expect(notes[0].contains("file not found"))
    }

    @Test("oversized files stay as notes (50 MB telegram cap)")
    func oversized() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("big-\(UUID().uuidString).bin")
        // Sparse file: 51 MB of zeros without allocating.
        FileManager.default.createFile(atPath: tmp.path, contents: Data())
        let fh = try FileHandle(forWritingTo: tmp)
        defer { try? fh.close(); try? FileManager.default.removeItem(at: tmp) }
        try fh.truncate(atOffset: 51 * 1024 * 1024)

        let (files, notes) = DeliveryManager.makeDeliverablePlan(paths: [tmp.path], platform: "telegram")
        #expect(files.isEmpty)
        #expect(notes.count == 1)
        #expect(notes[0].contains("limit"))
    }

    @Test("multipart body shape (Telegram sendDocument)")
    func multipart() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mp-\(UUID().uuidString).txt")
        try "payload-bytes".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let body = try TelegramAdapter.buildMultipart(
            fields: ["chat_id": "123", "caption": "report.txt"],
            fileField: "document",
            filePath: tmp.path
        )
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.hasPrefix("--\(TelegramAdapter.multipartBoundary)\r\n"))
        #expect(text.contains("name=\"chat_id\""))
        #expect(text.contains("123"))
        #expect(text.contains("name=\"document\"; filename=\"mp-"))
        #expect(text.contains("payload-bytes"))
        #expect(text.hasSuffix("--\(TelegramAdapter.multipartBoundary)--\r\n"))
    }

    @Test("MIME type guessing")
    func mime() {
        #expect(MimeTypes.guess(from: "/a/b/photo.png") == "image/png")
        #expect(MimeTypes.guess(from: "/a/b/doc.PDF") == "application/pdf")
        #expect(MimeTypes.guess(from: "/a/b/notes.txt") == "text/plain")
        #expect(MimeTypes.guess(from: "/a/b/archive.zip") == "application/zip")
        #expect(MimeTypes.guess(from: "/a/b/unknown.xyz") == nil)
    }
}
