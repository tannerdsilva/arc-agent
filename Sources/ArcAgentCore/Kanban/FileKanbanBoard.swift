import Foundation

/// A file-based kanban board backed by JSON files.
///
/// Each task is stored as a separate JSON file under the board directory.
/// This is the fallback JSON implementation — the no-dependency backend that
/// works without a Tessera server.
///
/// ## Concurrency
///
/// ``FileKanbanBoard`` is an **actor** — all state mutations are serialized.
/// Reads are concurrent; writes are exclusive.
public actor FileKanbanBoard: KanbanBoard {

    private let directory: URL
    private var cache: [String: KanbanTask] = [:]

    /// Create a file-based kanban board.
    ///
    /// - Parameter directory: The directory to store task files.
    ///   Defaults to `~/.arc/kanban/`.
    public init(directory: URL? = nil) {
        let dir = directory ?? ArcHome.kanban
        self.directory = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - KanbanBoard

    public func create(_ task: KanbanTask) async throws {
        // Duplicate detection consults the directory, not just `cache`: a fresh
        // instance starts empty, so an id another instance already wrote would
        // be silently overwritten — its result, parents and children lost.
        guard (cache[task.id] ?? load(id: task.id)) == nil else {
            throw KanbanError.duplicateId(task.id)
        }
        cache[task.id] = task
        try save(task)
    }

    public func get(id: String) async throws -> KanbanTask? {
        if let cached = cache[id] { return cached }
        return load(id: id)
    }

    public func update(_ task: KanbanTask) async throws {
        var updated = task
        updated.updatedAt = Date()
        cache[task.id] = updated
        try save(updated)
    }

    public func delete(id: String) async throws {
        let url = fileURL(for: id)
        // A swallowed removal error is worse than a noisy one: the file
        // survives, the caller is told the task is gone, and the next hydration
        // resurrects it. A task with no file at all is still evicted from cache.
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        cache[id] = nil
    }

    public func list(
        status: TaskStatus? = nil,
        assignee: String? = nil,
        limit: Int = 50
    ) async throws -> [KanbanTask] {
        hydrateFromDirectory()
        var tasks = Array(cache.values)

        if let status {
            tasks = tasks.filter { $0.status == status }
        }
        if let assignee {
            tasks = tasks.filter { $0.assignee == assignee }
        }

        return tasks
            .sorted { $0.priority > $1.priority || ($0.priority == $1.priority && $0.createdAt < $1.createdAt) }
            // Defence in depth: the tool rejects a non-positive limit, but the
            // CLI and the dispatcher reach this directly, and `prefix(_:)`
            // traps on a negative length.
            .prefix(max(0, limit))
            .map { $0 }
    }

    public func transition(id: String, to newStatus: TaskStatus) async throws {
        guard var task = cache[id] ?? load(id: id) else {
            throw KanbanError.notFound(id)
        }
        guard let allowed = defaultTransitions[task.status], allowed.contains(newStatus) else {
            throw KanbanError.invalidTransition(from: task.status, to: newStatus)
        }
        task.status = newStatus
        task.updatedAt = Date()
        cache[id] = task
        try save(task)
    }

    public func addDependency(parentID: String, childID: String) async throws {
        // A task that depends on itself can never satisfy its own parents.
        guard parentID != childID else {
            throw KanbanError.cycleDetected
        }
        guard var parent = cache[parentID] ?? load(id: parentID) else {
            throw KanbanError.notFound(parentID)
        }
        guard var child = cache[childID] ?? load(id: childID) else {
            throw KanbanError.notFound(childID)
        }

        // The edge is a set member, not a list entry: adding it twice is a
        // no-op. Either side recording it already means it is linked.
        if parent.children.contains(childID) || child.parents.contains(parentID) {
            return
        }

        // A cycle exists when the child already reaches the parent through its
        // own descendants — appending parent → child would close the loop. The
        // one-hop check this replaces caught only two-task loops, so a longer
        // ring (A → B → C, then C → A) built a board whose tasks could never
        // become ready.
        if reaches(childID, ancestor: parentID) {
            throw KanbanError.cycleDetected
        }

        parent.children.append(childID)
        child.parents.append(parentID)

        cache[parentID] = parent
        cache[childID] = child
        try save(parent)
        try save(child)
    }

    /// Whether `start` reaches `target` by following child edges.
    ///
    /// Reads through the cache and then the directory, so a cycle that spans
    /// tasks another instance wrote is still refused. `visited` bounds the walk
    /// even when the directory already holds a cycle.
    private func reaches(_ start: String, ancestor target: String) -> Bool {
        var visited: Set<String> = []
        var frontier = [start]
        while let current = frontier.popLast() {
            if current == target { return true }
            guard visited.insert(current).inserted else { continue }
            guard let task = cache[current] ?? load(id: current) else { continue }
            frontier.append(contentsOf: task.children)
        }
        return false
    }

    public func recomputeReady() async throws {
        // `cache` starts empty at construction, and `KanbanDispatcher` calls
        // this before its first `list`, so without hydration a restarted
        // daemon promotes nothing on its first tick.
        hydrateFromDirectory()

        // Snapshot: the loop below writes `cache` (`load` caches what it reads)
        // and a dictionary cannot be mutated while its values are iterated.
        for var task in Array(cache.values) where task.status == .todo {
            let allParentsDone = task.parents.allSatisfy { parentID in
                // A parent another instance completed is on disk but not in
                // this cache; treat it as the task it is, not as not-done.
                // A parent that exists nowhere still reads as not done.
                (cache[parentID] ?? load(id: parentID))?.status == .done
            }
            if allParentsDone {
                task.status = .ready
                cache[task.id] = task
                try save(task)
            }
        }
    }

    // MARK: - Persistence

    private func fileURL(for id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    private func save(_ task: KanbanTask) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(task)
        try data.write(to: fileURL(for: task.id), options: .atomic)
    }

    private func load(id: String) -> KanbanTask? {
        let url = fileURL(for: id)
        guard let data = try? Data(contentsOf: url),
              let task = try? JSONDecoder().decode(KanbanTask.self, from: data)
        else { return nil }
        cache[id] = task
        return task
    }

    /// Merge the tasks that are on disk into `cache`.
    ///
    /// `cache` starts empty at construction, so a freshly constructed board —
    /// a restarted daemon, a second process over the same directory, the CLI's
    /// `arc kanban list` — would otherwise list nothing until something read a
    /// task by id. Hydration closes that gap on the board's primary read path.
    ///
    /// An entry already in memory always wins: `update` has persisted it, and
    /// a deleted task's file is gone, so hydration can only add what this
    /// instance has not seen. A file that cannot be read or decoded is skipped
    /// — the same tolerance ``load(id:)`` has — rather than failing the list.
    ///
    /// The directory is the source of truth for tasks this instance has not
    /// touched; there is no watcher and no second cache. Every `list` re-reads
    /// it, which is what lets two live instances see each other's work.
    private func hydrateFromDirectory() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        let decoder = JSONDecoder()
        for url in entries where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let task = try? decoder.decode(KanbanTask.self, from: data)
            else { continue }
            if cache[task.id] == nil {
                cache[task.id] = task
            }
        }
    }
}
