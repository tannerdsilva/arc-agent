import Testing
import Foundation
@testable import ArcAgentCore

extension ArcCoreTestRoot {

    /// Settings backbone, slice 5: every config writer goes through the store.
    ///
    /// These tests run the built `arc` binary against a scratch `ARC_HOME`, so
    /// they exercise the same path an operator does — a subcommand's refusal
    /// has to be visible at the process boundary (exit status + stderr), not
    /// only as a thrown error inside a test process.
    ///
    /// Safety: every run points `ARC_HOME` at a fresh scratch directory and
    /// clears the ambient `ARC_*` variables, so the operator's real `~/.arc`
    /// is never read or written.
    @Suite("config write path", .serialized)
    struct ConfigWritePathTests {

        // MARK: - Fixtures

        enum ConfigWritePathError: Error { case binaryMissing }

        /// A fresh `ARC_HOME` whose `config.json` holds exactly `json`
        /// (`nil` = no file at all).
        private func scratchHome(_ json: String?) throws -> URL {
            let home = FileManager.default.temporaryDirectory
                .appendingPathComponent("arc-cli-write-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            if let json {
                try Data(json.utf8).write(to: home.appendingPathComponent("config.json"))
            }
            return home
        }

        private static func repoRoot() -> URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // ArcAgentCoreTests
                .deletingLastPathComponent()   // Tests
                .deletingLastPathComponent()   // repository
        }

        /// Locates the built `arc` binary. `swift build` must have run first
        /// (the test target does not build the executable itself).
        private static func arcBinary() throws -> URL {
            let candidates = ["debug", "arm64-apple-macosx/debug", "out/Products/Debug"]
                .map { repoRoot().appendingPathComponent(".build/\($0)/arc") }
            for url in candidates where FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
            throw ConfigWritePathError.binaryMissing
        }

        struct CommandResult {
            var status: Int32
            var stdout: String
            var stderr: String
        }

        /// Run `arc <arguments>` with `ARC_HOME` pointing at `home` and stdin
        /// closed (every prompt takes its default).
        private func run(
            _ arguments: [String],
            home: URL,
            stdin: String? = nil
        ) throws -> CommandResult {
            let process = Process()
            process.executableURL = try Self.arcBinary()
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            for key in environment.keys.filter({ $0.hasPrefix("ARC_") }) {
                environment.removeValue(forKey: key)
            }
            environment["ARC_HOME"] = home.path
            process.environment = environment

            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            if let stdin {
                let input = Pipe()
                process.standardInput = input
                try process.run()
                input.fileHandleForWriting.write(Data(stdin.utf8))
                try? input.fileHandleForWriting.close()
            } else {
                process.standardInput = FileHandle.nullDevice
                try process.run()
            }
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CommandResult(
                status: process.terminationStatus,
                stdout: String(decoding: outData, as: UTF8.self),
                stderr: String(decoding: errData, as: UTF8.self)
            )
        }

        // MARK: - The gate

        @Test("a corrupt config makes the writing subcommand fail loudly and changes no byte")
        func corruptConfigRefused() throws {
            let home = try scratchHome("{ not json")
            let url = home.appendingPathComponent("config.json")
            let before = try Data(contentsOf: url)

            let result = try run(["personality", "clear"], home: home)

            #expect(result.status != 0,
                    "a refused write must exit non-zero (got \(result.status)); stdout: \(result.stdout)")
            #expect(result.stderr.contains("Failed to parse config"),
                    "the parse error is reported on stderr; got: \(result.stderr)")
            #expect(try Data(contentsOf: url) == before,
                    "a refused write leaves the file byte-identical")
            #expect(!FileManager.default.fileExists(
                atPath: url.appendingPathExtension("bak").path),
                    "a refused write backs nothing up, because it never writes")
        }

        @Test("every writing subcommand refuses a corrupt config")
        func allWritersRefuse() throws {
            for arguments in [["personality", "clear"], ["personality", "set", "bogus"]] {
                let home = try scratchHome("{ not json")
                let url = home.appendingPathComponent("config.json")
                let before = try Data(contentsOf: url)

                let result = try run(arguments, home: home)

                #expect(result.status != 0,
                        "`arc \(arguments.joined(separator: " "))` must refuse (got \(result.status))")
                #expect(try Data(contentsOf: url) == before,
                        "`arc \(arguments.joined(separator: " "))` changed a file it cannot read")
            }
        }

        // MARK: - The happy path

        @Test("a valid config is written through the store in canonical shape")
        func validConfigWritten() throws {
            let home = try scratchHome("{\"agent\":{\"systemPrompt\":\"be terse\"}}")
            let url = home.appendingPathComponent("config.json")

            let result = try run(["personality", "clear"], home: home)

            #expect(result.status == 0, "stderr: \(result.stderr)")
            let written = try ConfigurationStore.readDeclared(url)
            #expect(written.agent.systemPrompt.isEmpty, "the clear landed")

            // one generation of backup is the store's write; a bare
            // `saveConfig` leaves none, so its presence proves the write path.
            #expect(FileManager.default.fileExists(
                atPath: url.appendingPathExtension("bak").path),
                    "the write goes through the store (backup + atomic replace)")

            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.contains("\"limits\""), "the canonical limits section is written")
            #expect(text.contains("\"tools\""), "the canonical tools section is written")
        }

        @Test("a second identical write is a no-op")
        func secondWriteIsNoOp() throws {
            let home = try scratchHome("{\"agent\":{\"systemPrompt\":\"be terse\"}}")
            let url = home.appendingPathComponent("config.json")

            #expect(try run(["personality", "clear"], home: home).status == 0)
            let afterFirst = try Data(contentsOf: url)

            #expect(try run(["personality", "clear"], home: home).status == 0)
            #expect(try Data(contentsOf: url) == afterFirst,
                    "nothing changed, so the store writes nothing")
        }

        @Test("setup edits the declaration instead of replacing it")
        func setupMerges() throws {
            let home = try scratchHome("{\"tools\":{\"disabledToolsets\":[\"x\"]}}")
            let url = home.appendingPathComponent("config.json")

            // instance dir (blank = default), provider, model; every later
            // prompt reads EOF and keeps the file's value.
            let result = try run(["setup"], home: home, stdin: "\nopenai\ncli-merge-test\n")
            #expect(result.status == 0, "stderr: \(result.stderr)")

            let written = try ConfigurationStore.readDeclared(url)
            #expect(written.model.defaultModel == "cli-merge-test", "the prompted value landed")
            #expect(written.tools.disabledToolsets == ["x"],
                    "a section the prompts never touch survives the write")
        }

        // MARK: - Source shape

        @Test("saveConfig has exactly one call site: the store's write primitive")
        func oneWritePrimitive() throws {
            let sources = Self.repoRoot().appendingPathComponent("Sources")
            let enumerator = FileManager.default.enumerator(
                at: sources, includingPropertiesForKeys: nil)
            var hits: [String] = []
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "swift",
                      let text = try? String(contentsOf: url, encoding: .utf8)
                else { continue }
                for (index, line) in text
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .enumerated() where line.contains("saveConfig(") {
                    // the declaration is not a call site.
                    if line.contains("func saveConfig(") { continue }
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    hits.append("\(url.lastPathComponent):\(index + 1): \(trimmed)")
                }
            }
            #expect(hits.count == 1,
                    "every writer goes through `DocumentStore.mutate`; found \(hits.count):\n\(hits.joined(separator: "\n"))")
            #expect(hits.first?.hasPrefix("ConfigurationStore.swift:") == true,
                    "the one call site is the store's write primitive, got: \(hits)")
        }
    }
}
