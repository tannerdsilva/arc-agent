import Foundation

// MARK: - Deliverable mode (Hermes `features/deliverable-mode.md`)

/// Scans agent responses for absolute file paths with supported extensions
/// (outside code fences / inline code), so the gateway can ship them as
/// native attachments and strip the path from the visible message.
public enum DeliverableExtractor {

    public static let extensions: Set<String> = [
        // Images
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "svg",
        // Video
        "mp4", "mov", "avi", "mkv", "webm", "3gp",
        // Audio
        "mp3", "m2a", "wav", "ogg", "opus", "m4a", "flac",
        // Documents
        "pdf", "docx", "doc", "odt", "rtf", "txt", "md", "epub",
        // Data
        "xlsx", "xls", "ods", "csv", "tsv", "json", "xml", "yaml", "yml",
        // Geospatial
        "kmz", "kml", "geojson", "gpx",
        // Presentations
        "pptx", "ppt", "odp", "key",
        // Archives
        "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "apk", "ipa",
        // Web
        "html", "htm",
    ]

    /// Returns (text with paths removed, extracted absolute paths).
    /// Paths inside fenced code blocks or backticks are ignored.
    public static func extract(_ text: String) -> (clean: String, paths: [String]) {
        var paths: [String] = []
        var clean = text

        // Build a mask of ranges inside ``` fences and inline `code`.
        var maskedRanges: [Range<String.Index>] = []
        var inFence = false
        var fenceStart = text.startIndex
        var inInline = false
        var inlineStart = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if inFence {
                if char == "\n" {
                    let rest = text[index...]
                    if rest.hasPrefix("\n```") {
                        let after = text.index(index, offsetBy: 4, limitedBy: text.endIndex) ?? text.endIndex
                        maskedRanges.append(fenceStart..<after)
                        inFence = false
                        index = after
                        if index >= text.endIndex { break }
                        continue
                    }
                }
                index = text.index(after: index)
                continue
            }
            if char == "`" {
                if !inInline {
                    inInline = true
                    inlineStart = index
                } else {
                    maskedRanges.append(inlineStart..<text.index(after: index))
                    inInline = false
                }
                index = text.index(after: index)
                continue
            }
            if text[index...].hasPrefix("```") {
                inFence = true
                fenceStart = index
                index = text.index(index, offsetBy: 3)
                continue
            }
            index = text.index(after: index)
        }
        if inFence { maskedRanges.append(fenceStart..<text.endIndex) }
        if inInline { maskedRanges.append(inlineStart..<text.endIndex) }

        func isMasked(_ range: Range<String.Index>) -> Bool {
            maskedRanges.contains { $0.overlaps(range) }
        }

        // Word scan (deterministic, no regex): each whitespace-delimited token
        // that starts with / or ~/ and ends in a supported extension is a
        // deliverable path. Trailing punctuation is trimmed from the path.
        var rawRanges: [(Range<String.Index>, String)] = []
        var wordIndex = text.startIndex
        while wordIndex < text.endIndex {
            // Skip separator run.
            while wordIndex < text.endIndex, text[wordIndex].isWhitespace {
                wordIndex = text.index(after: wordIndex)
            }
            let start = wordIndex
            while wordIndex < text.endIndex, !text[wordIndex].isWhitespace {
                wordIndex = text.index(after: wordIndex)
            }
            let token = String(text[start..<wordIndex])
            guard !token.isEmpty else { continue }
            let range = start..<wordIndex
            if !isMasked(range) {
                var trimmedToken = token
                while let last = trimmedToken.last, [",", ".", ";", "!", "?", ")", ":", "\""].contains(last) {
                    trimmedToken.removeLast()
                }
                if trimmedToken.hasPrefix("/") || trimmedToken.hasPrefix("~/") {
                    let ext = trimmedToken.split(separator: ".").last.map(String.init) ?? ""
                    if extensions.contains(ext.lowercased()) {
                        rawRanges.append((range, token))
                        paths.append(trimmedToken)
                    }
                }
            }
        }

        if !rawRanges.isEmpty {
            var mutable = text
            // Remove from the back so earlier ranges stay valid.
            for (range, _) in rawRanges.reversed() {
                mutable.replaceSubrange(range, with: "")
            }
            clean = mutable.replacingOccurrences(of: "  ", with: " ")
        }
        return (clean, paths)
    }
}
