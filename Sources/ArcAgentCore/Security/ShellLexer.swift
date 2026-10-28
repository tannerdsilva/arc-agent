import Foundation

// MARK: - Shell Lexing for Command Detection
//
// Port of Hermes' quote-aware shell lexing substrate (approval.py). Every
// detection layer — HardlineBlocker, SoftDetector, ExecutionFlagDetector —
// builds on these helpers. Nothing here executes a shell; all scans are
// pure string work over `[Character]` buffers.
//
// Key invariants carried over from the reference:
// - Quoted text is DATA. A `(` inside `--title "(reboot)"` never registers
//   a command start; `(reboot)` at a real subshell position always does.
// - Deobfuscation is narrow and non-executing: quote/escape stripping plus
//   literal-only `$(echo x)` / `${X:-default}` resolution, two rounds max.
// - Parser limits fail closed: oversized input is treated as dangerous.

enum ShellLexer {

    // MARK: Parser limits

    static let maxDetectionCommandChars = 128_000
    static let maxSeparatorFreeCommandChars = 4_096
    static let maxDetectionSegments = 25_000
    static let parserLimitDescription = "command parser limit exceeded"
    static let malformedExecDescription = "command parser limit or malformed executable payload"

    /// Bound all parser work before normalization/tokenization.
    static func parserLimitExceeded(_ command: String) -> Bool {
        if command.count > maxDetectionCommandChars { return true }
        if command.count > maxSeparatorFreeCommandChars,
           command.first(where: { $0 == ";" || $0 == "&" || $0 == "|" || $0 == "\n" }) == nil {
            return true
        }
        var separators = 0
        for ch in command where ch == ";" || ch == "&" || ch == "|" || ch == "\n" {
            separators += 1
            if separators >= maxDetectionSegments { return true }
        }
        return false
    }

    // MARK: Normalization

    /// Strip ECMA-48 escape sequences (CSI, OSC, 8-bit C1) so ANSI-styled
    /// output cannot smuggle patterns past detection.
    static func stripANSI(_ input: String) -> String {
        guard input.contains("\u{1B}") || input.contains("\u{9B}") else { return input }
        var out: [Character] = []
        out.reserveCapacity(input.count)
        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "\u{9B}" { i += 1; continue }  // 8-bit C1 CSI
            if ch == "\u{1B}" {
                if i + 1 < chars.count {
                    let next = chars[i + 1]
                    if next == "[" {
                        // CSI: consume through final byte 0x40–0x7E
                        var j = i + 2
                        while j < chars.count {
                            let scalars = chars[j].unicodeScalars
                            if scalars.count == 1, let s = scalars.first,
                               s.value >= 0x40 && s.value <= 0x7E { j += 1; break }
                            j += 1
                        }
                        i = j
                        continue
                    }
                    if next == "]" {
                        // OSC: terminated by BEL or ST (ESC \)
                        var j = i + 2
                        var terminated = false
                        while j < chars.count {
                            if chars[j] == "\u{07}" { j += 1; terminated = true; break }
                            if chars[j] == "\u{1B}", j + 1 < chars.count, chars[j + 1] == "\\" {
                                j += 2; terminated = true; break
                            }
                            j += 1
                        }
                        i = terminated ? j : chars.count
                        continue
                    }
                    if next == "P" || next == "X" || next == "^" || next == "_" {
                        // DCS/SOS/PM/APC: consume through ST
                        var j = i + 2
                        var terminated = false
                        while j < chars.count {
                            if chars[j] == "\u{1B}", j + 1 < chars.count, chars[j + 1] == "\\" {
                                j += 2; terminated = true; break
                            }
                            j += 1
                        }
                        i = terminated ? j : chars.count
                        continue
                    }
                }
                i += 1
                continue
            }
            out.append(ch)
            i += 1
        }
        return String(out)
    }

    /// Normalize a command string before dangerous-pattern matching:
    /// ANSI strip, NUL strip, Unicode NFKC, line-continuation collapse,
    /// home-prefix folding, backslash-escape strip, empty-quote strip,
    /// and `$IFS` collapse. Order mirrors the reference exactly.
    static func normalize(_ input: String) -> String {
        var command = stripANSI(input)
        command = command.replacingOccurrences(of: "\0", with: "")
        command = command.precomposedStringWithCompatibilityMapping  // NFKC
        // Collapse shell line continuations (backslash-newline) BEFORE the
        // generic backslash-escape strip so `rm -rf \<newline>/` → `rm -rf /`.
        command = collapseLineContinuations(command)
        command = foldHomePrefixes(command)
        // Strip shell backslash-escapes: r\m → rm.
        command = stripBackslashEscapes(command)
        // Strip empty-string literals that split tokens: r''m → rm.
        command = command
            .replacingOccurrences(of: "''", with: "")
            .replacingOccurrences(of: "\"\"", with: "")
        // Collapse $IFS / ${IFS...} word-separator expansions to a space.
        command = collapseIFS(command)
        return command
    }

    private static func collapseLineContinuations(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out: [Character] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count, chars[i + 1] == "\n" {
                i += 2
                continue
            }
            if chars[i] == "\\", i + 2 < chars.count, chars[i + 1] == "\r", chars[i + 2] == "\n" {
                i += 3
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return String(out)
    }

    /// Fold resolved absolute home prefixes into `~` so static `~/.ssh`
    /// style patterns catch `/Users/alice/.ssh` and `$HOME/.ssh` alike.
    static func foldHomePrefixes(_ command: String) -> String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        guard !home.isEmpty, home != "/" else { return command }
        var result = command
        // Longest/most-specific literal first; `${HOME}`/`$HOME` are matched
        // by the sensitive-path fragments themselves, so only the resolved
        // absolute form needs folding here.
        for candidate in [home + "/", home] {
            result = result.replacingOccurrences(of: candidate, with: candidate == home ? "~" : "~/")
        }
        return result
    }

    private static func stripBackslashEscapes(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out: [Character] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count, chars[i + 1] != "\n" {
                out.append(chars[i + 1])
                i += 2
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return String(out)
    }

    private static func collapseIFS(_ s: String) -> String {
        guard s.contains("IFS") else { return s }
        // ${IFS...} (any brace form) or bare $IFS → literal space.
        var out: [Character] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] == "$", i + 1 < chars.count, chars[i + 1] == "{" {
                // Scan a ${...} group; collapse if the name is IFS.
                var j = i + 2
                var depth = 1
                var name = ""
                while j < chars.count, depth > 0 {
                    if chars[j] == "{" { depth += 1 }
                    if chars[j] == "}" { depth -= 1; if depth == 0 { break } }
                    if depth == 1 { name.append(chars[j]) }
                    j += 1
                }
                if depth == 0 {
                    if name.hasPrefix("IFS") {
                        out.append(" ")
                        i = j + 1
                        continue
                    }
                    // Emit verbatim.
                    out.append(contentsOf: chars[i...j])
                    i = j + 1
                    continue
                }
            }
            if chars[i] == "$", i + 3 < chars.count || i + 4 == chars.count {
                // Bare $IFS at a word boundary.
                var j = i + 1
                var name = ""
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" {
                    name.append(chars[j]); j += 1
                }
                if name == "IFS" {
                    out.append(" ")
                    i = j
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return String(out)
    }

    // MARK: Quote-aware scanning primitives

    private static func isSeparator(_ ch: Character) -> Bool {
        ch == ";" || ch == "&" || ch == "|" || ch == "\n"
    }

    /// Yield top-level command segments in one left-to-right pass.
    /// Doubled `&&`/`||` are consumed as one boundary.
    static func topLevelSegments(_ command: String) -> [String] {
        var segments: [String] = []
        let chars = Array(command)
        var start = 0
        var quote: Character? = nil
        var escaped = false
        var i = 0
        func flush(_ upTo: Int) {
            if start < upTo { segments.append(String(chars[start..<upTo])) }
        }
        while i < chars.count {
            let ch = chars[i]
            if escaped {
                escaped = false
            } else if ch == "\\", quote != "'" {
                escaped = true
            } else if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "'" || ch == "\"" {
                quote = ch
            } else if isSeparator(ch) {
                flush(i)
                if (ch == "&" || ch == "|"), i + 1 < chars.count, chars[i + 1] == ch {
                    i += 1
                }
                start = i + 1
            }
            i += 1
        }
        flush(chars.count)
        return segments
    }

    private static func skipWhitespace(_ chars: [Character], _ pos: Int) -> Int {
        var p = pos
        while p < chars.count, chars[p].isWhitespace { p += 1 }
        return p
    }

    /// Quote-aware command start offsets: 0, after `;`/`&&`/`||`/`|`,
    /// after `$(`, after backticks, after bare `(`/`{` openers, after `\n`.
    /// Starts inside quotes are never produced.
    static func commandStarts(_ command: String) -> [Int] {
        var starts: [Int] = [0]
        let chars = Array(command)
        var quote: Character? = nil
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if quote == "'" {
                if ch == "'" { quote = nil }
                i += 1
                continue
            }
            if quote == "\"" {
                if ch == "\\", i + 1 < chars.count { i += 2; continue }
                if ch == "\"" { quote = nil; i += 1; continue }
                if i + 1 < chars.count, ch == "$", chars[i + 1] == "(" {
                    starts.append(i + 2)
                    i += 2
                    continue
                }
                i += 1
                continue
            }
            if ch == "'" || ch == "\"" { quote = ch; i += 1; continue }
            if ch == "\\", i + 1 < chars.count { i += 2; continue }
            if i + 1 < chars.count, ch == "$", chars[i + 1] == "(" {
                starts.append(i + 2)
                i += 2
                continue
            }
            if ch == "(" || ch == "{" { starts.append(i + 1); i += 1; continue }
            if ch == ";" { starts.append(i + 1); i += 1; continue }
            if ch == "&" {
                if i + 1 < chars.count, chars[i + 1] == "&" { starts.append(i + 2); i += 2 }
                else { starts.append(i + 1); i += 1 }
                continue
            }
            if ch == "|" {
                if i + 1 < chars.count, chars[i + 1] == "|" { starts.append(i + 2); i += 2 }
                else { starts.append(i + 1); i += 1 }
                continue
            }
            if ch == "\n" { starts.append(i + 1) }
            i += 1
        }
        var seen = Set<Int>()
        var result: [Int] = []
        for s in starts {
            let skipped = skipWhitespace(chars, s)
            if skipped < chars.count && !seen.contains(skipped) {
                seen.insert(skipped)
                result.append(skipped)
            }
        }
        return result
    }

    /// Insert a newline before each real (quote-aware) command start so the
    /// flat `_CMDPOS`-anchored patterns see `(reboot)` / `{ shutdown; }` while
    /// quoted prose stays untouched. `\n` is already a separator class member.
    static func markCommandStarts(_ command: String) -> String {
        let offsets = commandStarts(command).filter { $0 > 0 }.sorted()
        if offsets.isEmpty { return command }
        let chars = Array(command)
        var out: [Character] = []
        var previous = 0
        for offset in offsets {
            out.append(contentsOf: chars[previous..<offset])
            out.append("\n")
            previous = offset
        }
        out.append(contentsOf: chars[previous...])
        return String(out)
    }

    /// Replace raw newlines inside single/double quotes with a space.
    /// A newline in a quoted string is DATA, not a command separator; the
    /// flat `\n`-anchored patterns would otherwise fire on multi-line
    /// arguments (`git commit -m`, heredoc text) whose data line begins
    /// with e.g. `sudo reboot`. Unclosed quotes absorb following newlines
    /// exactly as the shell would.
    static func maskQuotedNewlines(_ command: String) -> String {
        guard command.contains("\n") else { return command }
        let chars = Array(command)
        var out: [Character] = []
        var quote: Character? = nil
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if let q = quote {
                if ch == "\\", q == "\"", i + 1 < chars.count {
                    out.append(chars[i]); out.append(chars[i + 1]); i += 2; continue
                }
                if ch == q { quote = nil }
                out.append(ch == "\n" ? " " : ch)
                i += 1
                continue
            }
            if ch == "'" || ch == "\"" { quote = ch }
            else if ch == "\\", i + 1 < chars.count {
                out.append(chars[i]); out.append(chars[i + 1]); i += 2; continue
            }
            out.append(ch)
            i += 1
        }
        return String(out)
    }

    // MARK: Word reading + deobfuscation

    private static func scanDollarParenEnd(_ chars: [Character], start: Int) -> Int? {
        var depth = 1
        var quote: Character? = nil
        var i = start + 2
        while i < chars.count {
            let ch = chars[i]
            if let q = quote {
                if ch == "\\", q == "\"", i + 1 < chars.count { i += 2; continue }
                if ch == q { quote = nil }
                i += 1
                continue
            }
            if ch == "'" || ch == "\"" { quote = ch; i += 1; continue }
            if ch == "\\", i + 1 < chars.count { i += 2; continue }
            if i + 1 < chars.count, ch == "$", chars[i + 1] == "(" { depth += 1; i += 2; continue }
            if ch == ")" {
                depth -= 1
                i += 1
                if depth == 0 { return i }
                continue
            }
            i += 1
        }
        return nil
    }

    private static func scanBacktickEnd(_ chars: [Character], start: Int) -> Int? {
        var i = start + 1
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count { i += 2; continue }
            if chars[i] == "`" { return i + 1 }
            i += 1
        }
        return nil
    }

    /// Read one shell word without executing expansions.
    /// Returns (start, end) character offsets and the raw word.
    static func readShellWord(_ command: String, from pos: Int) -> (start: Int, end: Int, word: String) {
        let chars = Array(command)
        let start = skipWhitespace(chars, pos)
        var i = start
        var quote: Character? = nil
        while i < chars.count {
            let ch = chars[i]
            if let q = quote {
                if ch == "\\", q == "\"", i + 1 < chars.count { i += 2; continue }
                if ch == q { quote = nil }
                i += 1
                continue
            }
            if ch == "'" || ch == "\"" { quote = ch; i += 1; continue }
            if ch == "\\", i + 1 < chars.count { i += 2; continue }
            if i + 1 < chars.count, ch == "$", chars[i + 1] == "(" {
                if let end = scanDollarParenEnd(chars, start: i) { i = end }
                else { i += 2 }
                continue
            }
            if i + 1 < chars.count, ch == "$", chars[i + 1] == "{" {
                if let idx = chars[(i + 2)...].firstIndex(of: "}") { i = idx + 1 }
                else { i += 2 }
                continue
            }
            if ch == "`" {
                if let end = scanBacktickEnd(chars, start: i) { i = end }
                else { i += 1 }
                continue
            }
            if ch.isWhitespace || ch == ";" || ch == "&" || ch == "|" { break }
            i += 1
        }
        guard start <= i, i <= chars.count else { return (start, start, "") }
        return (start, i, String(chars[start..<i]))
    }

    private static let paramReplacementPattern = try? NSRegularExpression(
        pattern: #"\$\{[^}/\s]+/[^}/]*/([^}]*)\}"#)
    private static let paramDefaultPattern = try? NSRegularExpression(
        pattern: #"\$\{[^}:}\s]+:-([^}]*)\}"#)
    private static let simpleLiteralPattern = try? NSRegularExpression(
        pattern: #"^[A-Za-z0-9_./:@%+=,-]+$"#)
    private static let envAssignmentPattern = try? NSRegularExpression(
        pattern: #"^[A-Za-z_][A-Za-z0-9_]*=.*$"#)

    private static func fullmatch(_ re: NSRegularExpression?, _ s: String) -> Bool {
        guard let re else { return false }
        let ns = s as NSString
        let range = NSRange(location: 0, length: ns.length)
        return re.firstMatch(in: s, options: [.anchored], range: range) != nil
    }

    static func isSimpleShellLiteral(_ value: String) -> Bool {
        !value.isEmpty && fullmatch(simpleLiteralPattern, value)
    }

    /// Resolve tiny literal command substitutions without executing a shell.
    static func literalCommandSubstitutionOutput(_ script: String) -> String? {
        guard let tokens = shellTokens(script), let first = tokens.first else { return nil }
        let command = first.lowercased()
        var args = Array(tokens.dropFirst())
        if command == "echo" {
            while let a0 = args.first, a0.hasPrefix("-"),
                  !a0.isEmpty, a0.dropFirst().allSatisfy({ $0 == "n" || $0 == "E" || $0 == "e" }) {
                args.removeFirst()
            }
            if args.count == 1, isSimpleShellLiteral(args[0]) { return args[0] }
            return nil
        }
        if command == "printf" {
            if args.count == 1, isSimpleShellLiteral(args[0]) { return args[0] }
            if args.count == 2, args[0] == "%s", isSimpleShellLiteral(args[1]) { return args[1] }
        }
        return nil
    }

    private static func replaceSimpleCommandSubstitutions(_ word: String) -> String {
        let chars = Array(word)
        var out: [Character] = []
        var i = 0
        while i < chars.count {
            if i + 1 < chars.count, chars[i] == "$", chars[i + 1] == "(" {
                if let end = scanDollarParenEnd(chars, start: i) {
                    let inner = String(chars[(i + 2)..<(end - 1)])
                    if let replacement = literalCommandSubstitutionOutput(inner) {
                        out.append(contentsOf: replacement)
                        i = end
                        continue
                    }
                }
            }
            if chars[i] == "`" {
                if let end = scanBacktickEnd(chars, start: i) {
                    let inner = String(chars[(i + 1)..<(end - 1)])
                    if let replacement = literalCommandSubstitutionOutput(inner) {
                        out.append(contentsOf: replacement)
                        i = end
                        continue
                    }
                }
            }
            out.append(chars[i])
            i += 1
        }
        return String(out)
    }

    private static func replaceSimpleShellExpansions(_ word: String) -> String {
        var result = replaceSimpleCommandSubstitutions(word)
        if let re = paramReplacementPattern {
            result = re.stringByReplacingMatches(
                in: result, range: NSRange(location: 0, length: (result as NSString).length),
                withTemplate: "$1")
        }
        if let re = paramDefaultPattern {
            result = re.stringByReplacingMatches(
                in: result, range: NSRange(location: 0, length: (result as NSString).length),
                withTemplate: "$1")
        }
        return result
    }

    private static func stripShellWordSyntax(_ word: String) -> String {
        let chars = Array(word)
        var out: [Character] = []
        var quote: Character? = nil
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if let q = quote {
                if ch == "\\", q == "\"", i + 1 < chars.count {
                    out.append(chars[i + 1]); i += 2; continue
                }
                if ch == q { quote = nil; i += 1; continue }
                out.append(ch); i += 1; continue
            }
            if ch == "'" || ch == "\"" { quote = ch; i += 1; continue }
            if ch == "\\", i + 1 < chars.count {
                out.append(chars[i + 1]); i += 2; continue
            }
            out.append(ch); i += 1
        }
        return String(out)
    }

    /// Approximate how shell syntax can spell a command word — narrow and
    /// non-executing: quoting/escaping plus simple literal substitutions,
    /// iterated to a fixed point (2 rounds max).
    static func deobfuscate(_ word: String) -> String {
        var deobfuscated = word
        for _ in 0..<2 {
            let previous = deobfuscated
            deobfuscated = replaceSimpleShellExpansions(deobfuscated)
            deobfuscated = stripShellWordSyntax(deobfuscated)
            if deobfuscated == previous { break }
        }
        return deobfuscated
    }

    static func isEnvAssignment(_ word: String) -> Bool {
        fullmatch(envAssignmentPattern, word)
    }

    // MARK: Command-position word spans

    static let commandWrapperWords: Set<String> = [
        "sudo", "env", "exec", "nohup", "setsid", "time", "command", "builtin",
    ]
    static let sudoOptionsWithArg: Set<String> = [
        "-c", "--close-from", "-g", "--group", "-h", "--host",
        "-p", "--prompt", "-u", "--user",
    ]

    /// Yield command-position words that may be executable names: walk up to
    /// 12 prefix words from each command start, skipping wrapper words and
    /// env assignments, deobfuscating each.
    static func commandWordSpans(_ command: String) -> [(start: Int, end: Int, word: String)] {
        var spans: [(Int, Int, String)] = []
        let chars = Array(command)
        for commandStart in commandStarts(command) {
            var pos = commandStart
            var prefixWords = 0
            var skipWrapperOptions = false
            var skipNextWrapperArg = false
            while prefixWords < 12 {
                let (wordStart, wordEnd, word) = readShellWord(command, from: pos)
                if wordStart == wordEnd { break }
                let deobfuscated = deobfuscate(word)
                let lowerWord = deobfuscated.lowercased()
                if skipNextWrapperArg {
                    skipNextWrapperArg = false
                    pos = wordEnd
                    prefixWords += 1
                    continue
                }
                if skipWrapperOptions, lowerWord.hasPrefix("-") {
                    let optionName = lowerWord.split(separator: "=", maxSplits: 1).first.map(String.init) ?? lowerWord
                    skipNextWrapperArg = !lowerWord.contains("=") && sudoOptionsWithArg.contains(optionName)
                    pos = wordEnd
                    prefixWords += 1
                    continue
                }
                spans.append((wordStart, wordEnd, word))
                prefixWords += 1
                _ = chars  // (kept for parity with reference; not otherwise used)
                if commandWrapperWords.contains(lowerWord) {
                    skipWrapperOptions = lowerWord == "sudo" || lowerWord == "env"
                    pos = wordEnd
                    continue
                }
                if isEnvAssignment(deobfuscated) {
                    skipWrapperOptions = false
                    pos = wordEnd
                    continue
                }
                break
            }
        }
        return spans
    }

    // MARK: shlex-compatible tokenization (posix, punctuation "<>")

    /// Tokenize like Python `shlex(s, posix=True, punctuation_chars="<>")`
    /// with `whitespace_split=True, commenters=""`. Returns nil on malformed
    /// quoting so callers can fail closed. Punctuation runs ("();<>|&" — the
    /// requested "<>" plus shlex's always-on base set) become single tokens.
    static func shellTokens(_ segment: String, start: Int) -> [String]? {
        let chars = Array(segment)
        var i = max(0, start)
        var tokens: [String] = []
        let punctuation: Set<Character> = ["(", ")", ";", "<", ">", "|", "&"]
        while i < chars.count {
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            if i >= chars.count { break }
            if punctuation.contains(chars[i]) {
                var run = String(chars[i])
                i += 1
                while i < chars.count, punctuation.contains(chars[i]) {
                    run.append(chars[i]); i += 1
                }
                tokens.append(run)
                continue
            }
            var value: [Character] = []
            var quote: Character? = nil
            var closed = true
            while i < chars.count {
                let ch = chars[i]
                if let q = quote {
                    if ch == q {
                        quote = nil; closed = true; i += 1; continue
                    }
                    if q == "\"" && ch == "\\", i + 1 < chars.count {
                        let next = chars[i + 1]
                        // Inside double quotes a backslash escapes the shell's
                        // escaped set only; otherwise it stays literal.
                        if next == "\"" || next == "\\" || next == "`" || next == "$" || next == "\n" {
                            if next != "\n" { value.append(next) }
                            i += 2
                            continue
                        }
                        value.append(ch); i += 1; continue
                    }
                    value.append(ch); i += 1; continue
                }
                if ch == "'" { quote = ch; i += 1; closed = false; continue }
                if ch == "\"" { quote = ch; i += 1; closed = false; continue }
                if ch == "\\" {
                    if i + 1 >= chars.count { return nil }  // trailing backslash
                    let next = chars[i + 1]
                    if next == "\n" { i += 2; continue }  // line continuation
                    value.append(next); i += 2; continue
                }
                if punctuation.contains(ch) || ch.isWhitespace { break }
                value.append(ch); i += 1
            }
            if !closed { return nil }  // unterminated quote
            tokens.append(String(value))
        }
        return tokens
    }

    /// Convenience wrapper: tokenize a full script (used for the verification-
    /// artifact exemption and literal command-substitution resolution).
    static func shellTokens(_ script: String) -> [String]? {
        shellTokens(script, start: 0)
    }

    /// Tokenize preserving source spans, as ``(value, start, end, inert)``
    /// where `inert` marks a wholly single-quoted operand (shell data).
    static func shellTokensWithSpans(
        _ segment: String, start: Int
    ) -> [(value: String, start: Int, end: Int, inert: Bool)]? {
        let chars = Array(segment)
        var i = max(0, start)
        var tokens: [(String, Int, Int, Bool)] = []
        while i < chars.count {
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            if i >= chars.count { break }
            let tokenStart = i
            var value: [Character] = []
            var quote: Character? = nil
            while i < chars.count {
                let ch = chars[i]
                if let q = quote {
                    if ch == q { quote = nil; i += 1; continue }
                    if ch == "\\", q == "\"", i + 1 < chars.count {
                        value.append(chars[i + 1]); i += 2; continue
                    }
                    value.append(ch); i += 1; continue
                }
                if ch == "'" || ch == "\"" { quote = ch; i += 1; continue }
                if ch == "\\" {
                    if i + 1 >= chars.count { return nil }
                    value.append(chars[i + 1]); i += 2; continue
                }
                if ch.isWhitespace { break }
                value.append(ch); i += 1
            }
            if quote != nil { return nil }
            let raw = String(chars[tokenStart..<i])
            let inertSingleQuoted =
                (raw.hasPrefix("'") && raw.hasSuffix("'"))
                || (raw.contains("='") && raw.hasSuffix("'"))
            tokens.append((String(value), tokenStart, i, inertSingleQuoted))
        }
        return tokens
    }

    // MARK: Grep-safe detection variant

    static let grepOptionsWithArg: Set<String> = [
        "--after-context", "--before-context", "--binary-files", "--context",
        "--directories", "--devices", "--exclude", "--exclude-dir",
        "--exclude-from", "--include", "--label", "--max-count",
        "--regexp", "--file",
    ]
    static let grepShortOptionsWithArg: Set<Character> = ["A", "B", "C", "D", "d", "e", "f", "m"]

    static func basename(_ path: String) -> String {
        if path.hasSuffix("/") { return String(path.dropLast().split(separator: "/").last ?? "") }
        return path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Structurally locate quoted grep PCRE operands and blank them out so
    /// `grep -P '(rm -rf /)'` patterns-as-data do not trip detection.
    /// Returns (masked command, malformed) — malformed input is returned
    /// byte-for-byte intact so nothing is hidden on an uncertain parse.
    static func grepSafeVariant(_ command: String) -> (String, Bool) {
        var spans: [(Int, Int)] = []
        var offset = 0
        for segment in topLevelSegments(command) {
            guard let at = command.range(of: segment, range: command.index(command.startIndex, offsetBy: offset)..<command.endIndex) else {
                return (command, true)
            }
            let segmentAt = offset
            offset = command.distance(from: command.startIndex, to: at.lowerBound) + segment.count
            for (start, _, word) in commandWordSpans(segment) {
                let exe = basename(deobfuscate(word)).lowercased()
                guard exe == "grep" || exe == "egrep" else { continue }
                guard let tokens = shellTokensWithSpans(segment, start: start) else {
                    return (command, true)
                }
                let args = Array(tokens.dropFirst())
                var pcre = false
                var explicitPatterns = false
                var patternIndexes: [Int] = []
                var operandIndex: Int? = nil
                var i = 0
                var options = true
                while i < args.count {
                    let token = args[i].value
                    if options && token == "--" { options = false; i += 1; continue }
                    if options && token.hasPrefix("--") {
                        let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
                        let option = parts[0]
                        let hasValue = parts.count > 1
                        if option == "--perl-regexp" { pcre = true }
                        if option == "--regexp" || option == "--file" { explicitPatterns = true }
                        if grepOptionsWithArg.contains(option) && !hasValue {
                            if i + 1 >= args.count { return (command, true) }
                            if option == "--regexp" { patternIndexes.append(i + 1) }
                            i += 2
                            continue
                        }
                        if option == "--regexp" && hasValue { patternIndexes.append(i) }
                        i += 1
                        continue
                    }
                    if options && token.hasPrefix("-") && token != "-" {
                        let letterChars = Array(token.dropFirst())
                        var j = 0
                        var advanced = false
                        while j < letterChars.count {
                            let ch = letterChars[j]
                            if ch == "P" { pcre = true }
                            if ch == "e" || ch == "f" { explicitPatterns = true }
                            if grepShortOptionsWithArg.contains(ch) {
                                if j + 1 < letterChars.count {
                                    if ch == "e" { patternIndexes.append(i) }
                                } else {
                                    if i + 1 >= args.count { return (command, true) }
                                    if ch == "e" { patternIndexes.append(i + 1) }
                                    i += 1
                                }
                                advanced = true
                                break
                            }
                            j += 1
                        }
                        _ = advanced
                        i += 1
                        continue
                    }
                    if operandIndex == nil { operandIndex = i }
                    i += 1
                }
                if !explicitPatterns {
                    guard let oi = operandIndex else { return (command, pcre) }
                    patternIndexes.append(oi)
                }
                if pcre {
                    for index in patternIndexes where args[index].inert {
                        spans.append((segmentAt + args[index].start, segmentAt + args[index].end))
                    }
                }
            }
        }
        if spans.isEmpty { return (command, false) }
        // Blank the spans (right-to-left on the character buffer).
        let chars = Array(command)
        var out = chars
        for (start, end) in spans {
            for k in start..<min(end, out.count) { out[k] = " " }
        }
        return (String(out), false)
    }

    // MARK: Detection variants

    /// All variants of the command that pattern layers must inspect:
    /// normalized + grep-masked, recursive execution-flag payloads,
    /// marked-command-start reconstruction, and per-word deobfuscations.
    static func detectionVariants(_ command: String) -> [String] {
        var variants: [String] = []
        var seen = Set<String>()
        func push(_ v: String) {
            if seen.insert(v).inserted { variants.append(v) }
        }
        // Mask quoted newlines BEFORE normalization: normalization strips
        // backslash-escapes and empty-quote pairs, which would corrupt the
        // quote tracking the masking relies on.
        let normalized = normalize(maskQuotedNewlines(command))
        let (grepSafe, _) = grepSafeVariant(normalized)
        push(grepSafe)
        // Program-bearing option payloads are parsed in their owning
        // command's context; surface each payload recursively.
        var pending = [normalized]
        var depth = 0
        while !pending.isEmpty, depth < 16 {
            depth += 1
            let variant = pending.removeLast()
            for payload in ExecutionFlagDetector.nestedPayloads(in: variant) {
                push(payload)
                let marked = markCommandStarts(payload)
                if marked != payload { push(marked) }
                pending.append(payload)
            }
        }
        // Subshell/brace-group openers: reconstruct with newlines at real
        // command starts (the quote-aware tokenizer's whole point).
        let marked = markCommandStarts(grepSafe)
        if marked != grepSafe { push(marked) }
        // Quoting/escaping can spell an executable name in pieces (r\m).
        for (wordStart, wordEnd, word) in commandWordSpans(normalized) {
            let deobfuscated = deobfuscate(word)
            guard !deobfuscated.isEmpty, deobfuscated != word else { continue }
            let chars = Array(normalized)
            guard wordStart <= wordEnd, wordEnd <= chars.count else { continue }
            let variant = String(chars[0..<wordStart]) + deobfuscated + String(chars[wordEnd...])
            push(variant)
        }
        return variants
    }

    // MARK: Verification-artifact cleanup exemption

    static let artifactNamePattern = try? NSRegularExpression(
        pattern: #"^(?:arc|hermes)-(?:verify|ad-hoc)-[A-Za-z0-9_.-]+$"#)

    /// True when the command only removes one arc ad-hoc temp script —
    /// exactly `rm -f <tmpdir>/arc-(verify|ad-hoc)-<slug>`, nothing else.
    /// Deliberately narrow: any extra flag, operand, quoting oddity, or
    /// symlink escape falls through to normal detection.
    static func isVerificationArtifactCleanup(_ command: String) -> Bool {
        guard let argv = shellTokens(command) else { return false }
        guard argv.count == 3, argv[0] == "rm", argv[1] == "-f" else { return false }
        let operand = argv[2]
        guard !operand.isEmpty, operand.hasSuffix("/") == false else { return false }
        let tempDir = realpath(realTemporaryDirectory())
        // Must be directly inside the temp dir (no traversal, no nesting).
        guard operand == tempDir + "/" + basename(operand) else { return false }
        let resolved = realpath(operand)
        guard resolved == tempDir + "/" + basename(resolved) else { return false }
        guard let re = artifactNamePattern else { return false }
        return fullmatch(re, basename(operand))
    }

    static func realTemporaryDirectory() -> String {
        let env = ProcessInfo.processInfo.environment
        let dir = env["TMPDIR"] ?? env["TMP"] ?? env["TEMP"] ?? "/tmp"
        return dir.hasSuffix("/") ? String(dir.dropLast()) : dir
    }

    static func realpath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let resolved = url.resolvingSymlinksInPath().path
        return resolved.isEmpty ? path : resolved
    }
}
