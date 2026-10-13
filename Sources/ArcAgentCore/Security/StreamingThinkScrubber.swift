import Foundation

// MARK: - Streaming think scrubber (reference `agent/think_scrubber.py`)

/// Stateful scrubber for reasoning/thinking blocks in STREAMED assistant
/// text. The batch ``ThinkScrubber/scrub(_:)`` is correct for a complete
/// string, but when it runs per-delta it destroys the block state that
/// downstream consumers rely on: a model that streams
/// `"<thinking>"`, `"let me check"`, `"</thinking>"` as three deltas would
/// have the open tag erased by the per-delta regex, so the close-tag state
/// never sees it and reasoning leaks to the user.
///
/// This state machine centralises tag-suppression at the upstream layer so
/// every consumer sees text that has already had reasoning blocks removed.
/// Partial tags at delta boundaries are held back until the next delta
/// resolves them, and end-of-stream flushing surfaces any held-back prose
/// that turned out not to be a real tag.
///
/// ## Usage
/// ```swift
/// let scrubber = StreamingThinkScrubber()
/// for delta in stream {
///     let visible = scrubber.feed(delta)
///     if !visible.isEmpty { emit(visible) }
/// }
/// let tail = scrubber.flush()   // at end of stream
/// if !tail.isEmpty { emit(tail) }
/// ```
///
/// Tag variants handled (case-insensitive): `<think>`, `<thinking>`,
/// `<reasoning>`, `<thought>`, `<REASONING_SCRATCHPAD>`.
///
/// Block-boundary rule for opens: an opening tag is only treated as a
/// reasoning-block opener when it appears at the start of the stream, after
/// a newline (optionally followed by whitespace), or when only whitespace
/// has been emitted on the current line — so prose that *mentions* the tag
/// name is not incorrectly suppressed. Closed pairs (`<tag>X</tag>`) are
/// always suppressed regardless of boundary.
public struct StreamingThinkScrubber: Sendable {

    static let openTagNames = ["think", "thinking", "reasoning", "thought", "REASONING_SCRATCHPAD"]
    static let openTags = openTagNames.map { "<\($0)>" }
    static let closeTags = openTagNames.map { "</\($0)>" }
    static let maxTagLen = openTags.map(\.count).max() ?? 0

    /// True while inside an opened block, waiting for a close tag. All text
    /// inside is discarded.
    private var inBlock = false
    /// Held-back partial-tag tail. Emitted or discarded on the next
    /// `feed()` or by `flush()`.
    private var buf = ""
    /// True iff the most recent emission ended with `\n`, or nothing has
    /// been emitted yet (start-of-stream counts as a boundary).
    private var lastEmittedEndedNewline = true

    public init() {}

    /// Reset all state. Call at the top of every new turn so a hung block
    /// from an interrupted prior stream cannot taint the next turn.
    public mutating func reset() {
        inBlock = false
        buf = ""
        lastEmittedEndedNewline = true
    }

    /// Feed one delta; return the scrubbed visible portion. May return an
    /// empty string when the entire delta is reasoning content or is being
    /// held back pending resolution of a partial tag at the boundary.
    public mutating func feed(_ text: String) -> String {
        if text.isEmpty { return "" }
        var buffer = buf + text
        buf = ""
        var out: [String] = []

        while !buffer.isEmpty {
            if inBlock {
                let (closeIdx, closeLen) = Self.findFirstTag(buffer, tags: Self.closeTags)
                if closeIdx == -1 {
                    // No close yet — hold back a potential partial close-tag
                    // prefix; discard everything else.
                    let held = Self.maxPartialSuffix(buffer, tags: Self.closeTags)
                    buf = held > 0 ? String(buffer.suffix(held)) : ""
                    return out.joined()
                }
                // Found close: discard block content + tag, continue.
                buffer = String(buffer.dropFirst(closeIdx + closeLen))
                inBlock = false
                continue
            }

            // Priority 1 — closed `<tag>X</tag>` pair anywhere in the
            // buffer. Closed pairs are always an intentional, bounded
            // construct, so no boundary gating.
            let pair = Self.findEarliestClosedPair(buffer)
            // Priority 2 — unterminated open tag at a block boundary.
            let (openIdx, openLen) = findOpenAtBoundary(buffer, alreadyEmitted: out)

            // Pick whichever match comes earliest in the buffer.
            if let pair, openIdx == -1 || pair.start <= openIdx {
                let preceding = Self.stripOrphanCloseTags(String(buffer.prefix(pair.start)))
                if !preceding.isEmpty {
                    out.append(preceding)
                    lastEmittedEndedNewline = preceding.hasSuffix("\n")
                }
                buffer = String(buffer.dropFirst(pair.end))
                continue
            }

            if openIdx != -1 {
                // Unterminated open at boundary — emit preceding, enter block,
                // continue loop with remainder.
                let preceding = Self.stripOrphanCloseTags(String(buffer.prefix(openIdx)))
                if !preceding.isEmpty {
                    out.append(preceding)
                    lastEmittedEndedNewline = preceding.hasSuffix("\n")
                }
                inBlock = true
                buffer = String(buffer.dropFirst(openIdx + openLen))
                continue
            }

            // No resolvable tag structure in buffer. Hold back any
            // partial-tag prefix at the tail so a split tag across deltas
            // isn't missed, then emit the rest.
            let held = max(
                Self.maxPartialSuffix(buffer, tags: Self.openTags),
                Self.maxPartialSuffix(buffer, tags: Self.closeTags)
            )
            let emitText: String
            if held > 0 {
                emitText = String(buffer.dropLast(held))
                buf = String(buffer.suffix(held))
            } else {
                emitText = buffer
                buf = ""
            }
            let cleaned = Self.stripOrphanCloseTags(emitText)
            if !cleaned.isEmpty {
                out.append(cleaned)
                lastEmittedEndedNewline = cleaned.hasSuffix("\n")
            }
            return out.joined()
        }
        return out.joined()
    }

    /// End-of-stream flush. If still inside an unterminated block, held-back
    /// content is discarded (leaking partial reasoning is worse than a
    /// truncated answer). Otherwise the held-back partial-tag tail is
    /// emitted verbatim — it turned out not to be a real tag prefix.
    public mutating func flush() -> String {
        if inBlock {
            buf = ""
            inBlock = false
            // Next feed() is a new stream — start-of-stream is a boundary.
            lastEmittedEndedNewline = true
            return ""
        }
        let tail = buf
        buf = ""
        // Do NOT derive the boundary flag from the flushed tail (e.g. a
        // held-back '<'). End-of-stream means the next feed() starts a new
        // model response.
        lastEmittedEndedNewline = true
        if tail.isEmpty { return "" }
        return Self.stripOrphanCloseTags(tail)
    }

    // MARK: - Internal helpers

    /// Return (earliest_index, tag_length) over `tags`, or (-1, 0).
    static func findFirstTag(_ buf: String, tags: [String]) -> (Int, Int) {
        let lower = buf.lowercased()
        var bestIdx = -1
        var bestLen = 0
        for tag in tags {
            let tl = tag.lowercased()
            if let range = lower.range(of: tl) {
                let idx = lower.distance(from: lower.startIndex, to: range.lowerBound)
                if bestIdx == -1 || idx < bestIdx {
                    bestIdx = idx
                    bestLen = tl.count
                }
            }
        }
        return (bestIdx, bestLen)
    }

    /// Return (start_idx, end_idx) of the earliest closed pair, else nil.
    /// A closed pair is `<tag>...</tag>` of any variant; matches are
    /// case-insensitive and non-greedy (closest close tag wins). When two
    /// tag variants could both match, the one whose open tag appears
    /// earlier wins.
    static func findEarliestClosedPair(_ buf: String) -> (start: Int, end: Int)? {
        let lower = buf.lowercased()
        var best: (start: Int, end: Int)?
        for (openTag, closeTag) in zip(openTags, closeTags) {
            let ol = openTag.lowercased()
            guard let or = lower.range(of: ol) else { continue }
            let oi = lower.distance(from: lower.startIndex, to: or.lowerBound)
            let searchStart = lower.index(or.lowerBound, offsetBy: ol.count)
            let cl = closeTag.lowercased()
            guard let cr = lower.range(of: cl, range: searchStart..<lower.endIndex) else { continue }
            let ci = lower.distance(from: lower.startIndex, to: cr.lowerBound)
            let end = ci + cl.count
            if best == nil || oi < best!.start {
                best = (oi, end)
            }
        }
        return best
    }

    /// Return the earliest block-boundary open tag (idx, len), or (-1, 0).
    func findOpenAtBoundary(_ buf: String, alreadyEmitted: [String]) -> (Int, Int) {
        let lower = buf.lowercased()
        var bestIdx = -1
        var bestLen = 0
        for tag in Self.openTags {
            let tl = tag.lowercased()
            var searchStart = lower.startIndex
            while true {
                guard let range = lower.range(of: tl, range: searchStart..<lower.endIndex) else { break }
                let idx = lower.distance(from: lower.startIndex, to: range.lowerBound)
                if isBlockBoundary(buf, idx: idx, alreadyEmitted: alreadyEmitted) {
                    if bestIdx == -1 || idx < bestIdx {
                        bestIdx = idx
                        bestLen = tl.count
                    }
                    break // first boundary hit for this tag is enough
                }
                searchStart = lower.index(range.lowerBound, offsetBy: 1)
            }
        }
        return (bestIdx, bestLen)
    }

    /// True iff position `idx` in `buf` is a block boundary:
    /// - buf position 0 AND the most recent emission ended with a newline
    ///   (or nothing has been emitted yet)
    /// - any position whose preceding text on the current line (since the
    ///   last newline in buf) is whitespace-only, AND if there is no newline
    ///   in the preceding buf portion, the most recent prior emission ended
    ///   with a newline.
    func isBlockBoundary(_ buf: String, idx: Int, alreadyEmitted: [String]) -> Bool {
        if idx == 0 {
            if let last = alreadyEmitted.last {
                return last.hasSuffix("\n")
            }
            return lastEmittedEndedNewline
        }
        let chars = Array(buf)
        let preceding = chars[0..<idx]
        var lastNL: Int?
        for i in stride(from: preceding.count - 1, through: 0, by: -1) {
            if preceding[i] == "\n" {
                lastNL = i
                break
            }
        }
        if let lastNL {
            // Newline present — text between it and the tag must be
            // whitespace-only.
            let between = preceding[(lastNL + 1)...]
            return between.allSatisfy { $0.isWhitespace }
        }
        // No newline in buf before the tag — boundary only if the prior
        // emission ended with a newline AND everything since is whitespace.
        let priorNewline = alreadyEmitted.last?.hasSuffix("\n") ?? lastEmittedEndedNewline
        return priorNewline && preceding.allSatisfy { $0.isWhitespace }
    }

    /// Return the longest buf-suffix that is a prefix of any tag. Only
    /// prefixes strictly shorter than the tag itself count. Case-insensitive.
    static func maxPartialSuffix(_ buf: String, tags: [String]) -> Int {
        if buf.isEmpty { return 0 }
        let lower = buf.lowercased()
        let maxCheck = min(lower.count, maxTagLen - 1)
        if maxCheck <= 0 { return 0 }
        for i in stride(from: maxCheck, through: 1, by: -1) {
            let suffix = lower.suffix(i)
            for tag in tags {
                let tl = tag.lowercased()
                if tl.count > i && tl.hasPrefix(suffix) {
                    return i
                }
            }
        }
        return 0
    }

    /// Remove any close tags from *text* (orphan-close handling). An orphan
    /// close tag has no matching open in the current scrubber state; it is
    /// always noise, stripped with any trailing whitespace.
    static func stripOrphanCloseTags(_ text: String) -> String {
        if !text.contains("</") { return text }
        let chars = Array(text)
        let lowerChars = chars.map { String($0).lowercased() }
        var out = ""
        var i = 0
        while i < chars.count {
            var matched = false
            if i + 1 < chars.count, chars[i] == "<", chars[i + 1] == "/" {
                for tag in closeTags {
                    let tl = tag.lowercased()
                    let tagChars = Array(tl)
                    if i + tagChars.count <= chars.count {
                        var same = true
                        for (j, tc) in tagChars.enumerated() {
                            if lowerChars[i + j] != String(tc) {
                                same = false
                                break
                            }
                        }
                        if same {
                            // Skip the tag and any trailing whitespace.
                            var j = i + tagChars.count
                            while j < chars.count && " \t\n\r".contains(chars[j]) {
                                j += 1
                            }
                            i = j
                            matched = true
                            break
                        }
                    }
                }
            }
            if !matched {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }
}
