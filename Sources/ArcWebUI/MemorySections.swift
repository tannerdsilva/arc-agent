import Foundation

/// `§`-entry splitting for the memory docs (MEMORY.md / USER.md / SOUL.md).
///
/// Memory entries are delimited by a bare `§` line. The web UI renders each
/// delimiter as a real line separator — in the read view AND the editor
/// (one textarea per entry, separators between them) — while the stored file
/// keeps its exact bytes. This is display-only: every transformation here
/// lives between `splitSections` and `joinSections`, and well-formed files
/// (delimiter strictly between entries) round-trip byte-exactly.
enum MemorySections {
    /// Split content into entry sections on lines that are exactly `§`
    /// (whitespace-tolerant). A `§` inside entry content is not a delimiter.
    static func splitSections(_ content: String) -> [String] {
        var sections: [String] = []
        var current: [String] = []
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces) == "§" {
                sections.append(current.joined(separator: "\n"))
                current = []
            } else {
                current.append(String(line))
            }
        }
        sections.append(current.joined(separator: "\n"))
        return sections
    }

    /// Reassemble editor sections with the canonical `"\n§\n"` delimiter.
    /// Well-formed inputs are byte-exact; files that begin or end with a
    /// bare `§` line rejoin with the delimiter's edge newlines canonicalized.
    static func joinSections(_ sections: [String]) -> String {
        sections.joined(separator: "\n§\n")
    }
}
