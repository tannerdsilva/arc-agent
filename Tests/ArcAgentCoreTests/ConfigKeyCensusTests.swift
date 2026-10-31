import Foundation
import Testing

/// Configuration keys must have a reader.
///
/// The failure this prevents: a key lands in `ArcConfig` (or in the UI's
/// `settings.json` document), the settings page grows a control for it, the
/// docs describe it — and nothing reads it. Slice 6 deleted nine such keys;
/// this census keeps the next one from being added silently.
///
/// A **reader** is an occurrence in code where the key is consumed:
///
/// - `ArcConfig.swift` declares the whole config document, so a key's readers
///   live in every *other* source file. A name that appears only in its own
///   declaration, initializer, `CodingKeys` case or decode line is dead.
/// - `AppSettings` is declared in `AppState.swift`, which then reads it across
///   three thousand lines. Excluding that file would flag live keys whose only
///   readers are there (and would count same-named properties of other types as
///   readers), so an `AppSettings` reader is a qualified `settings.<key>`
///   occurrence anywhere under `Sources/`.
///
/// Comments are stripped first: a doc comment that names a key is not a reader.
/// String literals are kept, because Swift interpolation
/// (`"\(config.max_turns)"`) is executable code.
///
/// A direct assignment (`settings.accent = hex`) is not a reader — it only
/// writes the key. The two `measuredDeadRetained` entries below are the keys
/// that measurement leaves; both were outside slice 6's fixed delete list.
@Suite("Config key census")
struct ConfigKeyCensusTests {
    private struct Declaration: Hashable {
        let type: String
        let key: String
        let file: String
        let line: Int

        var identity: String { "\(type).\(key)" }
    }

    private struct Source {
        let file: String
        let code: String
    }

    /// The one-way compatibility shims named by the settings-backbone plan.
    ///
    /// Each is read once — by the lift into the current shape — and the census
    /// cannot see a read inside the declaration file. This is an inventory, not
    /// a bypass: `allowlistsAreNotStale` fails if an entry stops naming a
    /// declared key.
    private static let legacyDecodeOnly: Set<String> = [
        "ArcConfig.max_turns",
        "ArcConfig.guardrails",
        "AgentConfig.max_turns",
        "AgentConfig.max_turn_duration",
        "AppSettings.smartApproval",
        "AppSettings.moaEnabled",
        "AppSettings.tesseraOff",
        "AppSettings.activeStorage",
        "AppSettings.disabledToolsets",
        "AppSettings.disabledSkills",
    ]

    /// Keys measured on 2026-10-31 with no read anywhere under `Sources/`, and
    /// deliberately **not** deleted by slice 6 (its delete list was fixed at
    /// nine). They are named with their measurement so the next pass can delete
    /// or wire them instead of re-deriving this. Nothing may be added here
    /// without the same measurement in the reason.
    private static let measuredDeadRetained: [String: String] = [:]

    // MARK: - The gate

    @Test("every configuration key is read outside its declaration")
    func everyKeyHasAReader() throws {
        let sources = try Self.sources()
        let declarations = Self.configurationDeclarations(in: sources)
        let allowed = Self.legacyDecodeOnly.union(Self.measuredDeadRetained.keys)

        let orphans = declarations
            .filter { Self.readerCount(of: $0, in: sources) == 0 }
            .filter { !allowed.contains($0.identity) }
            .map { "\($0.identity) (\($0.file):\($0.line))" }
            .sorted()

        #expect(orphans.isEmpty, """
            configuration keys with no reader: \
            \(orphans.joined(separator: "; "))
            Delete the key, give it a reader, or — if it is a deliberate legacy \
            shim — add it to `legacyDecodeOnly` with the others.
            """)
    }

    @Test("the census parses the declarations it claims to")
    func censusParsesTheDeclarations() throws {
        let sources = try Self.sources()
        let declarations = Self.configurationDeclarations(in: sources)
        let identities = Set(declarations.map(\.identity))

        // A parser regression must fail loudly instead of passing vacuously.
        try #require(
            declarations.count >= 100,
            "parsed only \(declarations.count) configuration keys — the census's parser has drifted"
        )
        for expected in [
            "ArcConfig.security", "ArcConfig.terminal", "CheckpointsConfig.maxSnapshots",
            "MemoryConfig.enabled", "AppSettings.theme", "AppSettings.scheduledJobs",
        ] {
            #expect(identities.contains(expected), "the census did not parse \(expected)")
        }
    }

    @Test("the allowlists name declared keys")
    func allowlistsAreNotStale() throws {
        let sources = try Self.sources()
        let identities = Set(Self.configurationDeclarations(in: sources).map(\.identity))

        for key in Self.legacyDecodeOnly.sorted() {
            #expect(identities.contains(key), "legacyDecodeOnly names \(key), which is no longer declared")
        }
        for key in Self.measuredDeadRetained.keys.sorted() {
            #expect(identities.contains(key), "measuredDeadRetained names \(key), which is no longer declared")
        }
    }

    // MARK: - Reading the source tree

    /// The package root, found by climbing from this file until a directory
    /// holds `Package.swift`, so the checkout can live anywhere.
    private static func packageRoot() throws -> URL {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
            let parent = root.deletingLastPathComponent()
            try #require(parent.path != root.path, "no Package.swift above this test file")
            root = parent
        }
        return root
    }

    private static func sources() throws -> [Source] {
        let root = try packageRoot()
        let directory = root.appendingPathComponent("Sources")
        let walker = try #require(
            FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil),
            "expected the package sources beside this test file at \(directory.path)"
        )

        var urls: [URL] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            urls.append(url)
        }
        urls.sort { $0.path < $1.path }
        try #require(urls.count >= 100, "expected the package sources; found \(urls.count) file(s)")

        return try urls.map { url in
            let text = try String(contentsOf: url, encoding: .utf8)
            let file = url.path.replacingOccurrences(of: root.path + "/", with: "")
            return Source(file: file, code: strippingComments(text))
        }
    }

    /// Comments blanked, strings intact, newlines preserved (so line numbers
    /// still point at the real file).
    private static func strippingComments(_ text: String) -> String {
        let characters = Array(text)
        var output: [Character] = []
        output.reserveCapacity(characters.count)
        var index = 0
        var blockDepth = 0
        var inString = false
        var inMultilineString = false

        func blank(_ character: Character) -> Character {
            character == "\n" ? "\n" : " "
        }

        while index < characters.count {
            let character = characters[index]

            if blockDepth > 0 {
                if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                    blockDepth += 1
                    output.append(contentsOf: "  ")
                    index += 2
                    continue
                }
                if character == "*", index + 1 < characters.count, characters[index + 1] == "/" {
                    blockDepth -= 1
                    output.append(contentsOf: "  ")
                    index += 2
                    continue
                }
                output.append(blank(character))
                index += 1
                continue
            }

            if inMultilineString {
                if character == "\"", index + 2 < characters.count,
                   characters[index + 1] == "\"", characters[index + 2] == "\"" {
                    inMultilineString = false
                    output.append(contentsOf: "\"\"\"")
                    index += 3
                    continue
                }
                output.append(character)
                index += 1
                continue
            }

            if inString {
                if character == "\\", index + 1 < characters.count {
                    output.append(character)
                    output.append(characters[index + 1])
                    index += 2
                    continue
                }
                output.append(character)
                if character == "\"" || character == "\n" {
                    inString = false
                }
                index += 1
                continue
            }

            if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                while index < characters.count, characters[index] != "\n" {
                    output.append(" ")
                    index += 1
                }
                continue
            }
            if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                blockDepth = 1
                output.append(contentsOf: "  ")
                index += 2
                continue
            }
            if character == "\"", index + 2 < characters.count,
               characters[index + 1] == "\"", characters[index + 2] == "\"" {
                inMultilineString = true
                output.append(contentsOf: "\"\"\"")
                index += 3
                continue
            }
            if character == "\"" {
                inString = true
                output.append(character)
                index += 1
                continue
            }
            output.append(character)
            index += 1
        }

        return String(output)
    }

    /// Stored properties of the config document (`ArcConfig.swift`) and of
    /// `AppSettings` (`AppState.swift`). Computed properties, `static` members,
    /// `let` constants, enum cases and function locals are not configuration
    /// keys and are skipped.
    private static func configurationDeclarations(in sources: [Source]) -> [Declaration] {
        var declarations: [Declaration] = []

        if let arc = sources.first(where: { $0.file == "Sources/ArcAgentCore/Config/ArcConfig.swift" }) {
            declarations += storedProperties(in: arc.code, file: arc.file, onlyType: nil)
        }
        if let app = sources.first(where: { $0.file == "Sources/ArcWebUI/AppState.swift" }) {
            declarations += storedProperties(in: app.code, file: app.file, onlyType: "AppSettings")
        }
        return declarations
    }

    private static func storedProperties(
        in code: String,
        file: String,
        onlyType: String?
    ) -> [Declaration] {
        var declarations: [Declaration] = []
        var currentType: String?

        for (offset, rawLine) in code.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(rawLine)

            if !line.hasPrefix(" "), let name = typeHeaderName(in: line) {
                currentType = name
                continue
            }
            if !line.hasPrefix(" "), line.trimmingCharacters(in: .whitespaces) == "}" {
                currentType = nil
                continue
            }
            guard let owner = currentType, onlyType == nil || owner == onlyType else { continue }
            guard let key = storedPropertyName(in: line) else { continue }
            declarations.append(Declaration(type: owner, key: key, file: file, line: offset + 1))
        }
        return declarations
    }

    private static func typeHeaderName(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("{") else { return nil }

        let keywords = ["struct ", "enum ", "class ", "actor "]
        let modifiers: Set<String> = [
            "", "public ", "internal ", "private ", "fileprivate ", "package ",
            "final ", "public final ", "internal final ", "package final ",
        ]
        for keyword in keywords {
            guard let range = trimmed.range(of: keyword) else { continue }
            guard modifiers.contains(String(trimmed[..<range.lowerBound])) else { continue }
            let rest = trimmed[range.upperBound...]
            let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            return name.isEmpty ? nil : String(name)
        }
        return nil
    }

    private static func storedPropertyName(in line: String) -> String? {
        guard line.hasPrefix("    "), !line.hasPrefix("        ") else { return nil }
        var rest = Substring(line).dropFirst(4)
        guard rest.first != " " else { return nil }

        var isStatic = false
        let modifiers = [
            "public ", "internal ", "private ", "fileprivate ", "package ",
            "static ", "class ", "lazy ",
        ]
        var matchedModifier = true
        while matchedModifier {
            matchedModifier = false
            for modifier in modifiers where rest.hasPrefix(modifier) {
                if modifier == "static " || modifier == "class " { isStatic = true }
                rest = rest.dropFirst(modifier.count)
                matchedModifier = true
            }
        }

        guard !isStatic, rest.hasPrefix("var ") else { return nil }
        rest = rest.dropFirst("var ".count)
        let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        guard !name.isEmpty else { return nil }

        let after = rest.dropFirst(name.count)
        guard after.first == ":" || after.first == "=" || after.first == "{" else { return nil }
        // A computed property has `{` before any `=`; it stores nothing.
        if let brace = after.firstIndex(of: "{") {
            if let equals = after.firstIndex(of: "="), equals < brace { return String(name) }
            return nil
        }
        return String(name)
    }

    /// Occurrences of the key in code, excluding direct assignments.
    ///
    /// `AppSettings` keys are matched as `settings.<key>` (see the type's doc
    /// comment); config-document keys are matched by name in every file but
    /// their declaration file.
    private static func readerCount(of declaration: Declaration, in sources: [Source]) -> Int {
        let pattern: String
        let files: [Source]
        if declaration.type == "AppSettings" {
            pattern = "\\bsettings\\.\(declaration.key)\\b"
            files = sources
        } else {
            guard let declaring = sources.first(where: { $0.file.hasSuffix("Config/ArcConfig.swift") }) else {
                return 0
            }
            pattern = "\\b\(declaration.key)\\b"
            files = sources.filter { $0.file != declaring.file }
        }

        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        var count = 0
        for source in files {
            let text = source.code as NSString
            let matches = regex.matches(in: source.code, range: NSRange(location: 0, length: text.length))
            for match in matches {
                var index = match.range.location + match.range.length
                while index < text.length, text.character(at: index) == 0x20 || text.character(at: index) == 0x09 {
                    index += 1
                }
                if index < text.length, text.character(at: index) == 0x3D { // "="
                    let next = index + 1 < text.length ? text.character(at: index + 1) : 0
                    if next != 0x3D { // not "=="
                        continue // a direct assignment is not a reader
                    }
                }
                count += 1
            }
        }
        return count
    }
}
