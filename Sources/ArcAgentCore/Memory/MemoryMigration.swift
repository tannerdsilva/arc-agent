import Foundation
import Logging

// MARK: - MemoryMigration
//
// GROUNDZERO slice 4 re-rooted every memory provider at the profile directory
// (`~/.arc/profiles/<name>/`), which is the directory `profile_edit` already
// read. The old global pair (`~/.arc/memories/MEMORY.md` / `USER.md`) then had
// no reader at all: for an install that predates the change, that is silent
// memory loss (ledger D15).
//
// This seed copies the legacy pair into each profile that does not have its
// own document. It runs **once**: a marker records that the relocation
// happened, so a profile created *later* starts empty — as a new agent should —
// instead of inheriting the previous agent's memory.
//
// Idempotence and the never-overwrite rule are two independent guards. Re-running
// after the marker is removed still copies nothing into a profile that has a
// document, and a second run in the same process logs nothing.

/// One-time relocation of the pre-profile memory documents.
public enum MemoryMigration {

    /// The documents a profile owns, in copy order.
    public static let documents = ["MEMORY.md", "USER.md"]

    /// Where memory lived before profiles: `~/.arc/memories/`.
    public static var legacyDirectory: URL { ArcHome.memories }

    /// Marker recording that the relocation has run. Sits beside the profile
    /// root rather than inside a profile, because it describes the install.
    public static var defaultMarker: URL {
        ArcHome.root.appendingPathComponent(".memory-migration-v1", isDirectory: false)
    }

    /// Relocate the legacy documents into every profile that lacks them.
    ///
    /// - Parameters:
    ///   - profiles: the roster. Only profiles present *now* are seeded, which
    ///     is what keeps a later profile empty.
    ///   - legacy: the old global memory directory (fixtures override this).
    ///   - profilesRoot: the profile root (fixtures override this).
    ///   - marker: the "already ran" marker.
    ///   - log: one line per copied file. Nothing is logged when there is
    ///     nothing to do.
    /// - Returns: the documents written, empty when there was nothing to do.
    @discardableResult
    public static func runIfNeeded(
        profiles: any ProfileStore,
        legacy: URL? = nil,
        profilesRoot: URL? = nil,
        marker: URL? = nil,
        log: ((String) -> Void)? = nil
    ) async -> [URL] {
        let fileManager = FileManager.default
        let markerURL = marker ?? defaultMarker
        // Already relocated: a second call is a no-op, including for profiles
        // that appeared since (they get nothing).
        guard !fileManager.fileExists(atPath: markerURL.path) else { return [] }

        let legacyDirectory = legacy ?? Self.legacyDirectory
        let root = profilesRoot
            ?? URL(fileURLWithPath: ProfileManager.profilesDir, isDirectory: true)
        let logger = Logger(label: "com.arc-agent.memory-migration")
        let emit: (String) -> Void = log ?? { logger.info("\($0)") }

        let roster: [Profile]
        do {
            roster = try await profiles.list()
        } catch {
            // An unreadable roster is not proof the relocation ran: leave the
            // marker unwritten so the next boot tries again.
            logger.warning("memory migration skipped: roster unreadable (\(error))")
            return []
        }

        var copied: [URL] = []
        for document in documents {
            let source = legacyDirectory.appendingPathComponent(document)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            for profile in roster {
                let directory = root.appendingPathComponent(profile.name, isDirectory: true)
                let destination = directory.appendingPathComponent(document)
                // Never overwrite: a profile that already has a document has
                // been writing its own memory, and the legacy file predates it.
                guard !fileManager.fileExists(atPath: destination.path) else { continue }
                do {
                    try fileManager.createDirectory(
                        at: directory, withIntermediateDirectories: true)
                    try fileManager.copyItem(at: source, to: destination)
                    emit("memory migration: copied \(document) into profile '\(profile.name)'")
                    copied.append(destination)
                } catch {
                    logger.warning(
                        "memory migration: could not copy \(document) into profile '\(profile.name)' (\(error))")
                }
            }
        }

        // Written whether or not anything was copied: an install with no legacy
        // files has nothing to relocate, now or later.
        do {
            try fileManager.createDirectory(
                at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: markerURL, options: .atomic)
        } catch {
            logger.warning("memory migration: could not write marker \(markerURL.path) (\(error))")
        }
        return copied
    }
}
