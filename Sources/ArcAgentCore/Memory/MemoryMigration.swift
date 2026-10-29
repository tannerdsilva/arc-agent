import ArcToolKit
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
//
// GROUNDZERO2 slice 5 added a second, independent seed at the bottom of this
// file: the web UI's Memory panel used to edit `~/.arc-agent-webui/MEMORY.md`
// and `USER.md`, documents no agent read. That seed has its own marker, because
// this one is already written on every migrated install.

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

    // MARK: - The dead web UI Memory panel (GROUNDZERO2 slice 5, D5)

    /// Where the web UI's Memory panel used to write: `~/.arc-agent-webui/`.
    ///
    /// That directory is UI *state* (settings, insights) and stays; only its
    /// `MEMORY.md` / `USER.md` were documents — documents no agent ever read,
    /// because the agent reads the profile's. `ArcHome.webUI` relocates with
    /// `ARC_HOME`, so an overridden instance's panel files are found too.
    public static var webUIPanelLegacyDirectory: URL { ArcHome.webUI }

    /// Marker for the panel seed — **its own**, not ``defaultMarker``.
    ///
    /// The relocation above records itself as `.memory-migration-v1` and runs
    /// at boot on every install, so reusing that marker would make this copy
    /// skip itself on precisely the machines that have legacy panel files.
    public static var webUIPanelMarker: URL {
        ArcHome.root.appendingPathComponent(".webui-memory-migration-v1", isDirectory: false)
    }

    /// Copy the dead panel's documents into `profile` once.
    ///
    /// Before GROUNDZERO2 slice 5 the panel wrote `~/.arc-agent-webui/MEMORY.md`
    /// and `USER.md`; the panel now edits the profile's own documents, and
    /// without this seed the text a human typed there would be stranded.
    ///
    /// `profile` is the profile the panel is editing (the active chat's, or
    /// `default` for an unbound chat). The legacy pair was one *global* pair,
    /// so it follows the human into the one profile they are looking at rather
    /// than being copied into every profile in the roster — and a profile that
    /// already has the document is never overwritten: it is the agent's own,
    /// and it is newer than anything the dead panel wrote.
    ///
    /// The legacy files are never deleted. A missing panel directory leaves the
    /// marker unwritten, so a later run (a downgrade that recreates it) is still
    /// migrated.
    ///
    /// - Returns: the destinations written — empty when there was nothing to do.
    @discardableResult
    public static func seedWebUIPanelDocuments(
        into profile: ProfileName,
        legacy: URL? = nil,
        profilesRoot: URL? = nil,
        marker: URL? = nil,
        log: ((String) -> Void)? = nil
    ) -> [URL] {
        let fileManager = FileManager.default
        let markerURL = marker ?? webUIPanelMarker
        // Already seeded: a second call is a no-op.
        guard !fileManager.fileExists(atPath: markerURL.path) else { return [] }

        let legacyDirectory = legacy ?? webUIPanelLegacyDirectory
        guard fileManager.fileExists(atPath: legacyDirectory.path) else { return [] }

        let root = profilesRoot
            ?? URL(fileURLWithPath: ProfileManager.profilesDir, isDirectory: true)
        let directory = root.appendingPathComponent(profile.rawValue, isDirectory: true)
        let logger = Logger(label: "com.arc-agent.webui-memory-migration")
        let emit: (String) -> Void = log ?? { logger.info("\($0)") }

        var copied: [URL] = []
        for document in documents {
            let source = legacyDirectory.appendingPathComponent(document)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = directory.appendingPathComponent(document)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            do {
                try fileManager.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                try fileManager.copyItem(at: source, to: destination)
                emit("memory panel migration: copied \(document) into profile '\(profile.rawValue)'")
                copied.append(destination)
            } catch {
                logger.warning(
                    "memory panel migration: could not copy \(document) into profile '\(profile.rawValue)' (\(error))")
            }
        }

        // Written whether or not anything was copied: an install whose legacy
        // panel documents are already in the profile has nothing left to move.
        do {
            try fileManager.createDirectory(
                at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: markerURL, options: .atomic)
        } catch {
            logger.warning(
                "memory panel migration: could not write marker \(markerURL.path) (\(error))")
        }
        return copied
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
