import Foundation
import Testing
@testable import ArcAgentCore

/// Fuzzy match engine (Hermes parity): all 9 strategies, replace_all gating,
/// already-applied detection, and no-match hints.
///
/// Newlines and unicode chars are built from scalars so the file itself
/// contains no backslash escapes (the patch/write transport escapes those).
let nw = String(UnicodeScalar(10))
let emd = String(UnicodeScalar(UInt32(0x2014))!)
let rsquo = String(UnicodeScalar(UInt32(0x2019))!)

@Suite("FuzzyMatch")
struct FuzzyMatchTests {

    @Test("exact single match replaces")
    func exactReplace() {
        let (result, count, strategy, error) = FuzzyMatch.fuzzyFindAndReplace(
            content: "hello world", old: "world", new: "Swift", replaceAll: false)
        #expect(count == 1)
        #expect(strategy == "exact")
        #expect(error == nil)
        #expect(result == "hello Swift")
    }

    @Test("exact replace_all replaces every occurrence")
    func exactReplaceAll() {
        let (result, count, strategy, _) = FuzzyMatch.fuzzyFindAndReplace(
            content: "a b a b a", old: "a", new: "X", replaceAll: true)
        #expect(count == 3)
        #expect(strategy == "exact")
        #expect(result == "X b X b X")
    }

    @Test("multiple exact matches without replace_all is an ambiguity error")
    func ambiguityGating() {
        let (result, count, strategy, error) = FuzzyMatch.fuzzyFindAndReplace(
            content: "a b a b", old: "a", new: "X", replaceAll: false)
        #expect(count == 0)
        #expect(strategy == nil)
        #expect(error?.contains("matches") == true)
        #expect(result == "a b a b")
    }

    @Test("line-trimmed strategy matches multiline pattern with indent drift")
    func lineTrimmedMultiline() {
        let content = "if true {" + nw + "        call()" + nw + "}"
        let (result, count, strategy, _) = FuzzyMatch.fuzzyFindAndReplace(
            content: content, old: "            call()", new: "call()", replaceAll: false)
        #expect(count == 1)
        #expect(strategy == "line_trimmed")
        #expect(result == "if true {" + nw + "        call()" + nw + "}")
    }

    @Test("whitespace-normalized strategy tolerates double spaces")
    func whitespaceStrategy() {
        let (result, count, strategy, _) = FuzzyMatch.fuzzyFindAndReplace(
            content: "let  x = 1", old: "let x = 1", new: "let y = 2", replaceAll: false)
        #expect(count == 1)
        #expect(strategy == "whitespace_normalized")
        #expect(result == "let y = 2")
    }

    @Test("escape-normalized strategy converts literal backslash-n")
    func escapeStrategy() {
        let (result, count, strategy, _) = FuzzyMatch.fuzzyFindAndReplace(
            content: "line1" + nw + "line2",
            old: "line1" + chrBSN() + "line2",
            new: "LINE1" + chrBSN() + "LINE2",
            replaceAll: false)
        #expect(count == 1)
        #expect(strategy == "escape_normalized")
        #expect(result == "LINE1" + nw + "LINE2")
    }

    @Test("trimmed-boundary strategy trims only first/last lines")
    func trimmedBoundaryStrategy() {
        let content = "  alpha" + nw + "  beta" + nw + "gamma  "
        let pattern = "alpha  " + nw + "  beta" + nw + "  gamma"
        let ranges = FuzzyMatch.strategyTrimmedBoundary(content, pattern)
        #expect(ranges.count == 1)
        if ranges.count == 1 {
            let chars = Array(content)
            let matched = String(chars[ranges[0].start..<ranges[0].end])
            #expect(matched == content)
        }
    }

    @Test("unicode-normalized strategy matches smart quotes")
    func unicodeStrategy() {
        let content = "It" + rsquo + "s here"
        let (result, count, strategy, _) = FuzzyMatch.fuzzyFindAndReplace(
            content: content, old: "It's here", new: "It is here", replaceAll: false)
        #expect(count == 1)
        #expect(strategy == "unicode_normalized")
        #expect(result == "It is here")
    }

    @Test("block-anchor strategy matches with fuzzy middles")
    func blockAnchorStrategy() {
        let content = "func a() {" + nw + "    one" + nw + "    two" + nw + "    three" + nw + "}"
        let pattern = "func a() {" + nw + "    one" + nw + "    XXXXX" + nw + "    three" + nw + "}"
        let (result, count, strategy, _) = FuzzyMatch.fuzzyFindAndReplace(
            content: content, old: pattern,
            new: "func a() {" + nw + "    ONE" + nw + "}", replaceAll: false)
        #expect(count == 1)
        #expect(strategy == "block_anchor")
        #expect(result == "func a() {" + nw + "    ONE" + nw + "}")
    }

    @Test("context-aware strategy matches all similar lines")
    func contextAwareStrategy() {
        let content = "let a = 1" + nw + "let b = 2" + nw + "let c = 3"
        let pattern = "let x = 1" + nw + "let y = 2" + nw + "let z = 3"
        let (result, count, strategy, _) = FuzzyMatch.fuzzyFindAndReplace(
            content: content, old: pattern,
            new: "let A = 1" + nw + "let B = 2" + nw + "let C = 3", replaceAll: false)
        #expect(count == 1)
        #expect(strategy == "context_aware")
        #expect(result == "let A = 1" + nw + "let B = 2" + nw + "let C = 3")
    }

    @Test("similarity strategies refuse replace_all on fuzzy matches")
    func similarityRefusesReplaceAll() {
        let block = "let a = 1" + nw + "let b = 2" + nw + "let c = 3"
        let content = block + nw + block
        let (_, count, _, error) = FuzzyMatch.fuzzyFindAndReplace(
            content: content,
            old: "let x = 1" + nw + "let y = 2" + nw + "let z = 3",
            new: "x", replaceAll: true)
        #expect(count == 0)
        #expect(error?.contains("approximate matches") == true)
    }

    @Test("reindentReplacement preserves file indentation")
    func reindentPreservesIndent() {
        let reindented = FuzzyMatch.reindentReplacement(
            fileRegion: "        call()", oldString: "    call()",
            newString: "    call2()" + nw + "    call3()")
        #expect(reindented == "        call2()" + nw + "        call3()")
    }

    @Test("isAlreadyApplied detects a landed edit")
    func alreadyApplied() {
        #expect(FuzzyMatch.isAlreadyApplied(content: "a" + nw + "b" + nw + "c", old: "a", new: "b") == false)
        #expect(FuzzyMatch.isAlreadyApplied(
            content: "already landed text goes here", old: "stale text",
            new: "already landed text goes here") == true)
    }

    @Test("no-match hint fires only for plain not-found errors")
    func noMatchHintGating() {
        let hint = FuzzyMatch.formatNoMatchHint(
            error: "Could not find a match for old_string in the file", matchCount: 0,
            old: "def totally_unique_name():", content: "def other_name():" + nw + "    pass")
        #expect(hint.contains("Did you mean one of these sections?") == true)
        let noHint = FuzzyMatch.formatNoMatchHint(
            error: "Found 2 matches for old_string", matchCount: 2,
            old: "x", content: "x x x")
        #expect(noHint.isEmpty)
    }

    @Test("empty and identical old/new are rejected")
    func emptyRejected() {
        let (_, c1, _, e1) = FuzzyMatch.fuzzyFindAndReplace(content: "abc", old: "", new: "x", replaceAll: false)
        #expect(c1 == 0 && e1?.contains("cannot be empty") == true)
        let (_, c2, _, e2) = FuzzyMatch.fuzzyFindAndReplace(content: "abc", old: "a", new: "a", replaceAll: false)
        #expect(c2 == 0 && e2?.contains("identical") == true)
    }

    @Test("multi-line exact replace keeps line structure")
    func multilineExact() {
        let content = "start" + nw + "func a() {" + nw + "    return 1" + nw + "}" + nw + "end"
        let (result, count, strategy, _) = FuzzyMatch.fuzzyFindAndReplace(
            content: content,
            old: "func a() {" + nw + "    return 1" + nw + "}",
            new: "func b() {" + nw + "    return 2" + nw + "}", replaceAll: false)
        #expect(count == 1)
        #expect(strategy == "exact")
        #expect(result == "start" + nw + "func b() {" + nw + "    return 2" + nw + "}" + nw + "end")
    }

    @Test("unicode positions map back correctly when normalization expands")
    func unicodeExpansionMapping() {
        // em-dash expands to two chars in normalized space; positions must map
        // back to the original single Character. The replacement keeps the
        // original em-dash in equal old/new regions (Hermes parity).
        let content = "a" + emd + "b"
        let (result, count, strategy, _) = FuzzyMatch.fuzzyFindAndReplace(
            content: content, old: "a--b", new: "a---b", replaceAll: false)
        #expect(count == 1)
        #expect(strategy == "unicode_normalized")
        #expect(result == "a" + emd + "-b")
    }
}

/// Literal backslash followed by `n` (2 chars), for escape-normalized tests.
private func chrBSN() -> String {
    String(UnicodeScalar(92)) + "n"
}
