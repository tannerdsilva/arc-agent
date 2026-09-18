import Foundation

// MARK: - Fuzzy matching engine
//
// Faithful Swift port of Hermes `tools/fuzzy_match.py` (multi-strategy find-
// and-replace, 9 strategies, unicode/escape/indent normalization, similarity
// fallbacks). Pure functions over strings — no I/O.
//
// Positions are tracked as integer offsets into [Character] arrays (matching
// Python's per-character indexing) and converted to String.Index exactly once
// at the boundary.

enum FuzzyMatch {

    /// Unicode → ASCII substitutions (smart quotes, dashes, ellipsis, NBSP,
    /// and the whole space-separator family).
    /// Unicode → ASCII substitutions (smart quotes, dashes, ellipsis, NBSP,
    /// and the whole space-separator family). Built from code points so the
    /// literal needs no backslash escaping.
    static let unicodeMap: [Character: String] = {
        func c(_ v: UInt32) -> Character { Character(UnicodeScalar(v)!) }
        return [
            c(0x201C): String(UnicodeScalar(34)!),  // left double quote → "
            c(0x201D): String(UnicodeScalar(34)!),  // right double quote → "
            c(0x2018): String(UnicodeScalar(39)!),  // left single quote → '
            c(0x2019): String(UnicodeScalar(39)!),  // right single quote → '
            c(0x2014): "--",  // em dash
            c(0x2013): "-",   // en dash
            c(0x2026): "...", // ellipsis
            c(0x00A0): " ",   // no-break space
            c(0x2212): "-",   // unicode minus
            c(0x2002): " ", c(0x2003): " ",  // en/em space
            c(0x2004): " ", c(0x2005): " ", c(0x2006): " ",  // per-em spaces
            c(0x2007): " ", c(0x2008): " ",  // figure/punctuation space
            c(0x2009): " ", c(0x200A): " ",  // thin/hair space
            c(0x202F): " ",  // narrow no-break space
            c(0x205F): " ",  // medium mathematical space
            c(0x3000): " ",  // ideographic space
        ]
    }()

    static func unicodeNormalize(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            if let repl = unicodeMap[ch] { out += repl } else { out.append(ch) }
        }
        return out
    }

    // MARK: - Public API

    /// Returns (newContent, matchCount, strategy, error).
    static func fuzzyFindAndReplace(
        content: String, old: String, new: String, replaceAll: Bool
    ) -> (String, Int, String?, String?) {
        if old.isEmpty {
            return (content, 0, nil, "old_string cannot be empty")
        }
        if old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (content, 0, nil, "old_string is only whitespace — provide non-blank text to match")
        }
        if old == new {
            return (content, 0, nil, "old_string and new_string are identical")
        }

        let strategies: [(String, (String, String) -> [CharRange])] = [
            ("exact", strategyExact),
            ("line_trimmed", strategyLineTrimmed),
            ("whitespace_normalized", strategyWhitespaceNormalized),
            ("indentation_flexible", strategyIndentationFlexible),
            ("escape_normalized", strategyEscapeNormalized),
            ("trimmed_boundary", strategyTrimmedBoundary),
            ("unicode_normalized", strategyUnicodeNormalized),
            ("block_anchor", strategyBlockAnchor),
            ("context_aware", strategyContextAware),
        ]
        let similarityStrategies: Set<String> = ["block_anchor", "context_aware"]

        for (name, fn) in strategies {
            let matches = fn(content, old)
            if matches.isEmpty { continue }

            if matches.count > 1 && !replaceAll {
                let locations = formatMatchLocations(content: content, matches: matches)
                return (content, 0, nil,
                    "Found \(matches.count) matches for old_string. "
                    + "Provide more context to make it unique, or use replace_all=True. "
                    + "Matches:\n\(locations)")
            }
            if replaceAll && matches.count > 1 && similarityStrategies.contains(name) {
                return (content, 0, nil,
                    "Found \(matches.count) approximate matches via the "
                    + "'\(name)' strategy; replace_all only applies to exact "
                    + "matches. Provide the precise text (whitespace included) so an "
                    + "exact/line-trimmed match can be made.")
            }
            if name != "exact" {
                if let drift = detectEscapeDrift(content: content, matches: matches, old: old, new: new) {
                    return (content, 0, nil, drift)
                }
            }

            var effectiveNew = maybeUnescapeNewString(new, content: content, matches: matches)
            if name == "unicode_normalized" {
                effectiveNew = preserveUnicodeInReplacement(
                    content: content, matches: matches, old: old, new: effectiveNew)
            }
            let newContent = applyReplacements(
                content: content, matches: matches, newString: effectiveNew,
                oldString: name == "exact" ? nil : old)
            return (newContent, matches.count, name, nil)
        }

        return (content, 0, nil, "Could not find a match for old_string in the file")
    }

    /// True when the requested edit is already present in the file (re-send
    /// of an edit that already landed). Conservative, per Hermes semantics.
    static func isAlreadyApplied(content: String, old: String, new: String) -> Bool {
        if new.isEmpty || new.trimmingCharacters(in: .whitespacesAndNewlines).count < 8 {
            return false
        }
        guard content.contains(new) else { return false }
        if old == new { return true }
        return !content.contains(old)
    }

    /// 'Did you mean...' hint for plain no-match errors.
    static func formatNoMatchHint(error: String?, matchCount: Int, old: String, content: String) -> String {
        if matchCount != 0 { return "" }
        guard let error, error.hasPrefix("Could not find") else { return "" }
        let hint = findClosestLines(old: old, content: content)
        return hint.isEmpty ? "" : "\n\nDid you mean one of these sections?\n" + hint
    }

    // MARK: - Character-position helpers

    /// Character index range into the original string.
    typealias CharRange = (start: Int, end: Int)

    static func toRange(_ cr: CharRange, in content: String) -> Range<String.Index>? {
        let chars = Array(content)
        guard cr.start >= 0, cr.end <= chars.count, cr.start <= cr.end else { return nil }
        let s = content.index(content.startIndex, offsetBy: cr.start)
        let e = content.index(content.startIndex, offsetBy: cr.end)
        return s..<e
    }

    static func ranges(_ matches: [CharRange], in content: String) -> [Range<String.Index>] {
        matches.compactMap { toRange($0, in: content) }
    }

    static func splitLines(_ s: String) -> [String] {
        s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// Exact, non-overlapping search over character arrays (str.replace semantics).
    static func exactSearch(_ haystack: [Character], _ needle: [Character]) -> [CharRange] {
        guard !needle.isEmpty, needle.count <= haystack.count else { return [] }
        var matches: [CharRange] = []
        var i = 0
        while i + needle.count <= haystack.count {
            var j = 0
            while j < needle.count && haystack[i + j] == needle[j] { j += 1 }
            if j == needle.count {
                matches.append((i, i + needle.count))
                i += needle.count
            } else {
                i += 1
            }
        }
        return matches
    }

    // MARK: - Strategy implementations

    /// Strategy 1: exact string match (non-overlapping).
    static func strategyExact(_ content: String, _ pattern: String) -> [CharRange] {
        exactSearch(Array(content), Array(pattern))
    }

    /// Strategy 2: line-by-line whitespace trimming.
    static func strategyLineTrimmed(_ content: String, _ pattern: String) -> [CharRange] {
        let contentLines = splitLines(content)
        let normalizedLines = contentLines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let patternNormalized = splitLines(pattern)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\n")
        return findNormalizedMatches(content: content, contentLines: contentLines,
                                     normalizedLines: normalizedLines,
                                     patternNormalized: patternNormalized)
    }

    /// Strategy 3: collapse runs of spaces/tabs to a single space.
    static func strategyWhitespaceNormalized(_ content: String, _ pattern: String) -> [CharRange] {
        let contentNorm = whitespaceNormalized(content)
        let patternNorm = whitespaceNormalized(pattern)
        let normMatches = exactSearch(Array(contentNorm), Array(patternNorm))
        if normMatches.isEmpty { return [] }
        return mapWhitespacePositions(original: content, normalized: contentNorm, matches: normMatches)
    }

    /// Strategy 4: ignore leading indentation per line.
    static func strategyIndentationFlexible(_ content: String, _ pattern: String) -> [CharRange] {
        let contentLines = splitLines(content)
        let strippedLines = contentLines.map { String($0.drop(while: { $0 == " " || $0 == "\t" })) }
        let patternStripped = splitLines(pattern)
            .map { String($0.drop(while: { $0 == " " || $0 == "\t" })) }
            .joined(separator: "\n")
        return findNormalizedMatches(content: content, contentLines: contentLines,
                                     normalizedLines: strippedLines,
                                     patternNormalized: patternStripped)
    }

    /// Strategy 5: convert literal escape sequences to real characters.
    static func strategyEscapeNormalized(_ content: String, _ pattern: String) -> [CharRange] {
        let unescaped = unescape(pattern)
        if unescaped == pattern { return [] }
        return exactSearch(Array(content), Array(unescaped))
    }

    /// Strategy 6: trim whitespace from first and last lines only.
    static func strategyTrimmedBoundary(_ content: String, _ pattern: String) -> [CharRange] {
        var patternLines = splitLines(pattern)
        guard !patternLines.isEmpty else { return [] }
        patternLines[0] = patternLines[0].trimmingCharacters(in: .whitespacesAndNewlines)
        if patternLines.count > 1 {
            patternLines[patternLines.count - 1] = patternLines[patternLines.count - 1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let modifiedPattern = patternLines.joined(separator: "\n")
        let contentLines = splitLines(content)
        guard contentLines.count >= patternLines.count else { return [] }

        var matches: [CharRange] = []
        for i in 0...(contentLines.count - patternLines.count) {
            var block = Array(contentLines[i..<(i + patternLines.count)])
            block[0] = block[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if block.count > 1 {
                block[block.count - 1] = block[block.count - 1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if block.joined(separator: "\n") == modifiedPattern {
                matches.append(calculateLinePositions(contentLines: contentLines,
                                                      startLine: i,
                                                      endLine: i + patternLines.count,
                                                      contentLength: Array(content).count))
            }
        }
        return matches
    }

    /// Strategy 7: unicode normalization (smart quotes, dashes, spaces).
    static func strategyUnicodeNormalized(_ content: String, _ pattern: String) -> [CharRange] {
        let normPattern = unicodeNormalize(pattern)
        let normContent = unicodeNormalize(content)
        if normContent == content && normPattern == pattern { return [] }
        var normMatches = exactSearch(Array(normContent), Array(normPattern))
        if normMatches.isEmpty {
            // line-trimmed fallback on normalized strings
            let contentLines = splitLines(normContent)
            let normalizedLines = contentLines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let patternNormalized = splitLines(normPattern)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: "\n")
            normMatches = findNormalizedMatches(content: normContent, contentLines: contentLines,
                                                normalizedLines: normalizedLines,
                                                patternNormalized: patternNormalized)
        }
        if normMatches.isEmpty { return [] }
        let map = buildOrigToNormMap(original: content)
        return mapPositionsNormToOrig(origToNorm: map, normMatches: normMatches)
    }

    /// Strategy 8: anchor on first/last lines, similarity threshold on middle.
    static func strategyBlockAnchor(_ content: String, _ pattern: String) -> [CharRange] {
        let contentChars = Array(content)
        let patternChars = Array(pattern)
        let normPattern = unicodeNormalize(pattern)
        let normContent = unicodeNormalize(content)
        let patternLines = splitLines(normPattern)
        if patternLines.count < 2 { return [] }
        let firstLine = patternLines[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let lastLine = patternLines[patternLines.count - 1].trimmingCharacters(in: .whitespacesAndNewlines)
        let normContentLines = splitLines(normContent)
        let origContentLines = splitLines(content)
        let count = patternLines.count
        guard normContentLines.count >= count else { return [] }

        var candidates: [Int] = []
        for i in 0...(normContentLines.count - count) {
            if normContentLines[i].trimmingCharacters(in: .whitespacesAndNewlines) == firstLine,
               normContentLines[i + count - 1].trimmingCharacters(in: .whitespacesAndNewlines) == lastLine {
                candidates.append(i)
            }
        }
        let threshold = candidates.count == 1 ? 0.50 : 0.70
        var matches: [CharRange] = []
        for i in candidates {
            let similarity: Double
            if count <= 2 {
                similarity = 1.0
            } else {
                let middleContent = normContentLines[(i + 1)..<(i + count - 1)].joined(separator: "\n")
                let middlePattern = patternLines[1..<(count - 1)].joined(separator: "\n")
                similarity = TextDiff.ratio(middleContent, middlePattern)
            }
            if similarity >= threshold {
                matches.append(calculateLinePositions(contentLines: origContentLines,
                                                      startLine: i,
                                                      endLine: i + count,
                                                      contentLength: contentChars.count))
            }
        }
        return matches
    }

    /// Strategy 9 (last resort): anchored per-line similarity, all lines >= 0.80.
    static func strategyContextAware(_ content: String, _ pattern: String) -> [CharRange] {
        let contentChars = Array(content)
        let patternLines = splitLines(pattern)
        let contentLines = splitLines(content)
        guard !patternLines.isEmpty, patternLines.count <= contentLines.count else { return [] }
        let firstPat = patternLines[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let lastPat = patternLines[patternLines.count - 1].trimmingCharacters(in: .whitespacesAndNewlines)
        let anchorThreshold = 0.80

        var matches: [CharRange] = []
        for i in 0...(contentLines.count - patternLines.count) {
            let block = Array(contentLines[i..<(i + patternLines.count)])
            if sim(firstPat, block[0].trimmingCharacters(in: .whitespacesAndNewlines)) < anchorThreshold { continue }
            if sim(lastPat, block[block.count - 1].trimmingCharacters(in: .whitespacesAndNewlines)) < anchorThreshold { continue }
            var allMatch = true
            for (pLine, cLine) in zip(patternLines, block) {
                let pStripped = pLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if pStripped.isEmpty { continue }
                if sim(pStripped, cLine.trimmingCharacters(in: .whitespacesAndNewlines)) < 0.80 {
                    allMatch = false
                    break
                }
            }
            if allMatch {
                matches.append(calculateLinePositions(contentLines: contentLines,
                                                      startLine: i,
                                                      endLine: i + patternLines.count,
                                                      contentLength: contentChars.count))
            }
        }
        return matches
    }

    // MARK: - Helpers

    static func whitespaceNormalized(_ s: String) -> String {
        var out = ""
        var pendingSpace = false
        for ch in s {
            if ch == " " || ch == "\t" {
                pendingSpace = true
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.append(ch)
        }
        if pendingSpace { out.append(" ") }
        return out
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\r", with: "\r")
    }

    static func leadingWhitespace(_ line: String) -> String {
        var i = line.startIndex
        while i < line.endIndex, line[i] == " " || line[i] == "\t" {
            i = line.index(after: i)
        }
        return String(line[line.startIndex..<i])
    }

    static func sim(_ a: String, _ b: String) -> Double {
        if a == b { return 1.0 }
        return TextDiff.ratio(a, b)
    }

    static func firstMeaningfulLine(_ text: String) -> String? {
        for line in splitLines(text) {
            if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return line
            }
        }
        return nil
    }

    static func findNormalizedMatches(
        content: String, contentLines: [String], normalizedLines: [String],
        patternNormalized: String
    ) -> [CharRange] {
        let patternLines = splitLines(patternNormalized)
        let count = patternLines.count
        guard contentLines.count >= count else { return [] }
        var matches: [CharRange] = []
        for i in 0...(contentLines.count - count) {
            let block = normalizedLines[i..<(i + count)].joined(separator: "\n")
            if block == patternNormalized {
                matches.append(calculateLinePositions(contentLines: contentLines,
                                                      startLine: i,
                                                      endLine: i + count,
                                                      contentLength: Array(content).count))
            }
        }
        return matches
    }

    static func calculateLinePositions(
        contentLines: [String], startLine: Int, endLine: Int, contentLength: Int
    ) -> CharRange {
        var start = 0
        for j in 0..<startLine {
            start += Array(contentLines[j]).count + 1
        }
        var end = 0
        for j in 0..<endLine {
            end += Array(contentLines[j]).count + 1
        }
        end -= 1
        end = min(contentLength, end)
        return (start, end)
    }

    /// Builds [Int]: index i (char offset in original) → normalized char offset.
    /// Because unicode replacements may EXPAND (em-dash → '--'), the normalized
    /// string can be longer; this map is the inverse lookup for mapping back.
    static func buildOrigToNormMap(original: String) -> [Int] {
        var result: [Int] = []
        var normPos = 0
        for ch in original {
            result.append(normPos)
            normPos += unicodeMap[ch].map { $0.count } ?? 1
        }
        result.append(normPos)
        return result
    }

    static func mapPositionsNormToOrig(
        origToNorm: [Int], normMatches: [CharRange]
    ) -> [CharRange] {
        var normToOrigStart: [Int: Int] = [:]
        for (origPos, normPos) in origToNorm.dropLast().enumerated() {
            if normToOrigStart[normPos] == nil { normToOrigStart[normPos] = origPos }
        }
        let origLen = origToNorm.count - 1
        var results: [CharRange] = []
        for (normStart, normEnd) in normMatches {
            guard let origStart = normToOrigStart[normStart] else { continue }
            var origEnd = origStart
            while origEnd < origLen && origToNorm[origEnd] < normEnd {
                origEnd += 1
            }
            results.append((origStart, origEnd))
        }
        return results
    }

    static func mapWhitespacePositions(
        original: String, normalized: String, matches: [CharRange]
    ) -> [CharRange] {
        let origChars = Array(original)
        let normChars = Array(normalized)
        var origToNorm: [Int] = []
        var oi = 0, ni = 0
        while oi < origChars.count && ni < normChars.count {
            if origChars[oi] == normChars[ni] {
                origToNorm.append(ni); oi += 1; ni += 1
            } else if (origChars[oi] == " " || origChars[oi] == "\t") && normChars[ni] == " " {
                origToNorm.append(ni); oi += 1
                if oi < origChars.count && !(origChars[oi] == " " || origChars[oi] == "\t") {
                    ni += 1
                }
            } else if origChars[oi] == " " || origChars[oi] == "\t" {
                origToNorm.append(ni); oi += 1
            } else {
                origToNorm.append(ni); oi += 1
            }
        }
        while oi < origChars.count {
            origToNorm.append(normChars.count); oi += 1
        }

        var normToOrigStart: [Int: Int] = [:]
        var normToOrigEnd: [Int: Int] = [:]
        for (origPos, normPos) in origToNorm.enumerated() {
            if normToOrigStart[normPos] == nil { normToOrigStart[normPos] = origPos }
            normToOrigEnd[normPos] = origPos
        }

        var result: [CharRange] = []
        for (normStart, normEnd) in matches {
            let origStart: Int
            if let s = normToOrigStart[normStart] {
                origStart = s
            } else {
                origStart = origToNorm.enumerated().first(where: { $0.element >= normStart })?.offset
                    ?? max(0, origToNorm.count - 1)
            }
            var origEnd: Int
            if let e = normToOrigEnd[normEnd - 1] {
                origEnd = e + 1
            } else {
                origEnd = origStart + (normEnd - normStart)
            }
            // Expand to include trailing whitespace only when the normalized
            // match itself ended with whitespace (word-boundary preservation).
            if normEnd < normChars.count && normChars[normEnd - 1] == " " {
                while origEnd < origChars.count && (origChars[origEnd] == " " || origChars[origEnd] == "\t") {
                    origEnd += 1
                }
            }
            result.append((origStart, min(origEnd, origChars.count)))
        }
        return result
    }

    static func applyReplacements(
        content: String, matches: [CharRange], newString: String, oldString: String?
    ) -> String {
        var chars = Array(content)
        let sortedMatches = matches.sorted { $0.start > $1.start }
        for m in sortedMatches {
            let replacement: String
            if let oldString {
                let region = String(chars[m.start..<m.end])
                replacement = reindentReplacement(fileRegion: region, oldString: oldString, newString: newString)
            } else {
                replacement = newString
            }
            let replChars = Array(replacement)
            chars.replaceSubrange(m.start..<m.end, with: replChars)
        }
        return String(chars)
    }

    static func reindentReplacement(fileRegion: String, oldString: String, newString: String) -> String {
        if newString.isEmpty { return newString }
        guard let oldFirst = firstMeaningfulLine(oldString),
              let fileFirst = firstMeaningfulLine(fileRegion) else { return newString }
        let oldIndent = leadingWhitespace(oldFirst)
        let fileIndent = leadingWhitespace(fileFirst)
        if oldIndent == fileIndent { return newString }

        var outLines: [String] = []
        for line in splitLines(newString) {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                outLines.append(line)
                continue
            }
            let lineIndent = leadingWhitespace(line)
            if lineIndent.hasPrefix(oldIndent) {
                let remainder = String(line.dropFirst(oldIndent.count))
                outLines.append(fileIndent + remainder)
            } else {
                outLines.append(fileIndent + line.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return outLines.joined(separator: "\n")
    }

    static func maybeUnescapeNewString(_ newString: String, content: String, matches: [CharRange]) -> String {
        if !newString.contains("\\t") && !newString.contains("\\r") && !newString.contains("\\n") {
            return newString
        }
        let chars = Array(content)
        var matchedRegions = ""
        for m in matches {
            matchedRegions += String(chars[m.start..<m.end])
        }
        var out = newString
        if out.contains("\\t") && matchedRegions.contains("\t") {
            out = out.replacingOccurrences(of: "\\t", with: "\t")
        }
        if out.contains("\\r") && matchedRegions.contains("\r") {
            out = out.replacingOccurrences(of: "\\r", with: "\r")
        }
        if out.contains("\\n") && matchedRegions.contains("\n") {
            out = out.replacingOccurrences(of: "\\n", with: "\n")
        }
        return out
    }

    static func preserveUnicodeInReplacement(
        content: String, matches: [CharRange], old: String, new: String
    ) -> String {
        let chars = Array(content)
        var fileRegion = ""
        for m in matches { fileRegion += String(chars[m.start..<m.end]) }

        let normOld = unicodeNormalize(old)
        let normFile = unicodeNormalize(fileRegion)
        if normOld != normFile { return new }

        let fileOrigToNorm = buildOrigToNormMap(original: fileRegion)
        var fileNormToOrig: [Int: Int] = [:]
        for (origPos, np) in fileOrigToNorm.dropLast().enumerated() {
            if fileNormToOrig[np] == nil { fileNormToOrig[np] = origPos }
        }

        let opcodes = TextDiff.opcodes(normOld, new)
        var resultParts: [String] = []
        for op in opcodes {
            switch op.tag {
            case "equal":
                let origStart = fileNormToOrig[op.i1] ?? 0
                var origEnd = origStart
                while origEnd < fileRegion.count
                    && (fileOrigToNorm[origEnd] < op.i2 || fileOrigToNorm[origEnd] == fileOrigToNorm[origStart]) {
                    if fileOrigToNorm[origEnd] >= op.i2 { break }
                    origEnd += 1
                }
                let rChars = Array(fileRegion)
                resultParts.append(String(rChars[origStart..<min(origEnd, rChars.count)]))
            case "replace", "insert":
                let nChars = Array(new)
                resultParts.append(String(nChars[op.j1..<min(op.j2, nChars.count)]))
            case "delete":
                break
            default:
                break
            }
        }
        return resultParts.joined()
    }

    static func detectEscapeDrift(content: String, matches: [CharRange], old: String, new: String) -> String? {
        if !new.contains("\\'") && !new.contains("\\\"") {
            return nil
        }
        let chars = Array(content)
        var matchedRegions = ""
        for m in matches { matchedRegions += String(chars[m.start..<m.end]) }
        for suspect in ["\\'", "\\\""] {
            if new.contains(suspect) && old.contains(suspect) && !matchedRegions.contains(suspect) {
                let plain = suspect.hasSuffix("'") ? "'" : "\""
                return "Escape-drift detected: old_string and new_string contain "
                    + "the literal sequence \(suspect) but the matched region of "
                    + "the file does not. This is almost always a tool-call "
                    + "serialization artifact where an apostrophe or quote got "
                    + "prefixed with a spurious backslash. Re-read the file with "
                    + "read_file and pass old_string/new_string without "
                    + "backslash-escaping \(plain) characters."
            }
        }
        return nil
    }

    static func formatMatchLocations(content: String, matches: [CharRange], cap: Int = 5) -> String {
        let chars = Array(content)
        var rows: [String] = []
        for m in matches.prefix(cap) {
            let lineNo = chars[0..<m.start].filter { $0 == "\n" }.count + 1
            var lineStart = m.start
            while lineStart > 0 && chars[lineStart - 1] != "\n" { lineStart -= 1 }
            var lineEnd = lineStart
            while lineEnd < chars.count && chars[lineEnd] != "\n" { lineEnd += 1 }
            var snippet = String(chars[lineStart..<lineEnd]).trimmingCharacters(in: .whitespaces)
            if snippet.count > 80 {
                snippet = String(snippet.prefix(77)) + "..."
            }
            rows.append("  L\(lineNo): \(snippet)")
        }
        let extra = matches.count - cap
        if extra > 0 {
            rows.append("  ... and \(extra) more")
        }
        return rows.joined(separator: "\n")
    }

    static func findClosestLines(old: String, content: String, contextLines: Int = 2, maxResults: Int = 3) -> String {
        var oldLines = splitLines(old)
        guard !oldLines.isEmpty else { return "" }
        let contentLines = splitLines(content)
        guard !contentLines.isEmpty else { return "" }

        var anchor = oldLines[0].trimmingCharacters(in: .whitespacesAndNewlines)
        if anchor.isEmpty {
            let candidates = oldLines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard let first = candidates.first else { return "" }
            anchor = first
        }

        var scored: [(ratio: Double, index: Int)] = []
        for (i, line) in contentLines.enumerated() {
            let stripped = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if stripped.isEmpty { continue }
            let r = TextDiff.ratio(anchor, stripped)
            if r > 0.3 { scored.append((r, i)) }
        }
        if scored.isEmpty { return "" }
        scored.sort { $0.ratio > $1.ratio }
        let top = Array(scored.prefix(maxResults))

        var parts: [String] = []
        var seenRanges = Set<String>()
        for (_, lineIdx) in top {
            let start = max(0, lineIdx - contextLines)
            let end = min(contentLines.count, lineIdx + oldLines.count + contextLines)
            let key = "\(start)-\(end)"
            if seenRanges.contains(key) { continue }
            seenRanges.insert(key)
            var snippetLines: [String] = []
            for j in start..<end {
                snippetLines.append(String(format: "\(start + j + 1)4| \(contentLines[j])"))
            }
            parts.append(snippetLines.joined(separator: "\n"))
        }
        if parts.isEmpty { return "" }
        var result = parts.joined(separator: "\n---\n")

        let bestLine = contentLines[top[0].index]
        if bestLine.trimmingCharacters(in: .whitespacesAndNewlines) == anchor && bestLine != oldLines[0] {
            result += "\n\nWhitespace difference detected (→ = tab, · = space):\n"
                + "  file has: \(visualizeWhitespace(bestLine))\n"
                + "  you sent: \(visualizeWhitespace(oldLines[0]))\n"
                + "Use the exact whitespace shown in 'file has'."
        }
        return result
    }

    static func visualizeWhitespace(_ line: String) -> String {
        var out = ""
        var i = line.startIndex
        while i < line.endIndex, line[i] == " " || line[i] == "\t" {
            out.append(line[i] == "\t" ? "→" : "·")
            i = line.index(after: i)
        }
        return out + String(line[i...])
    }
}

// MARK: - TextDiff (minimal difflib-like LCS)

enum TextDiff {

    /// difflib ratio(): 2 * LCS / (lenA + lenB), over Characters.
    static func ratio(_ a: String, _ b: String) -> Double {
        let ca = Array(a), cb = Array(b)
        if ca.isEmpty && cb.isEmpty { return 1.0 }
        let lcs = lcsLength(ca, cb)
        return 2.0 * Double(lcs) / Double(ca.count + cb.count)
    }

    static func lcsLength(_ a: [Character], _ b: [Character]) -> Int {
        var prev = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            var cur = [Int](repeating: 0, count: b.count + 1)
            for j in 1...b.count {
                if a[i - 1] == b[j - 1] {
                    cur[j] = prev[j - 1] + 1
                } else {
                    cur[j] = max(prev[j], cur[j - 1])
                }
            }
            prev = cur
        }
        return prev[b.count]
    }

    struct Opcode {
        let tag: String  // equal | replace | delete | insert
        let i1: Int, i2: Int, j1: Int, j2: Int
    }

    /// difflib get_opcodes() equivalent (LCS DP backtrack).
    static func opcodes(_ a: String, _ b: String) -> [Opcode] {
        let ca = Array(a), cb = Array(b)
        let n = ca.count, m = cb.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if ca[i] == cb[j] {
                    dp[i][j] = dp[i + 1][j + 1] + 1
                } else {
                    dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }
        var result: [Opcode] = []
        var i = 0, j = 0
        while i < n && j < m {
            if ca[i] == cb[j] {
                let iStart = i, jStart = j
                while i < n && j < m && ca[i] == cb[j] {
                    i += 1; j += 1
                }
                result.append(Opcode(tag: "equal", i1: iStart, i2: i, j1: jStart, j2: j))
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                let iStart = i
                while i < n && j < m && ca[i] != cb[j] && dp[i + 1][j] >= dp[i][j + 1] {
                    i += 1
                }
                result.append(Opcode(tag: "delete", i1: iStart, i2: i, j1: j, j2: j))
            } else {
                let jStart = j
                while i < n && j < m && ca[i] != cb[j] && dp[i + 1][j] < dp[i][j + 1] {
                    j += 1
                }
                result.append(Opcode(tag: "insert", i1: i, i2: i, j1: jStart, j2: j))
            }
        }
        if i < n {
            result.append(Opcode(tag: "delete", i1: i, i2: n, j1: j, j2: j))
        }
        if j < m {
            result.append(Opcode(tag: "insert", i1: i, i2: i, j1: j, j2: m))
        }
        // Simplify adjacent delete+insert into replace (difflib behavior).
        var simplified: [Opcode] = []
        for op in result {
            if op.tag == "delete",
               let last = simplified.last,
               last.tag == "insert" && last.i2 == op.i1 && last.j1 == op.j1 {
                simplified[simplified.count - 1] = Opcode(tag: "replace", i1: last.i1, i2: op.i2, j1: last.j1, j2: last.j2)
            } else if op.tag == "insert",
                      let last = simplified.last,
                      last.tag == "delete" && last.j2 == op.j1 && last.i1 == op.i1 {
                simplified[simplified.count - 1] = Opcode(tag: "replace", i1: last.i1, i2: last.i2, j1: last.j1, j2: op.j2)
            } else {
                simplified.append(op)
            }
        }
        return simplified
    }
}
