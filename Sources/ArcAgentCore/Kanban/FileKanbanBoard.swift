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
        let dir = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arc/kanban")
        self.directory = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - KanbanBoard

    public func create(_ task: KanbanTask) async throws {
        guard cache[task.id] == nil else {
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
        cache[id] = nil
        let url = fileURL(for: id)
        try? FileManager.default.removeItem(at: url)
    }

    public func list(
        status: TaskStatus? = nil,
        assignee: String? = nil,
        limit: Int = 50
    ) async throws -> [KanbanTask] {
        var tasks = Array(cache.values)

        if let status {
            tasks = tasks.filter { $0.status == status }
        }
        if let assignee {
            tasks = tasks.filter { $0.assignee == assignee }
        }

        return tasks
            .sorted { $0.priority > $1.priority || ($0.priority == $1.priority && $0.createdAt < $1.createdAt) }
            .prefix(limit)
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
        guard var parent = cache[parentID] ?? load(id: parentID) else {
            throw KanbanError.notFound(parentID)
        }
        guard var child = cache[childID] ?? load(id: childID) else {
            throw KanbanError.notFound(childID)
        }

        // Check for cycles: does child already depend on parent?
        if parent.parents.contains(childID) || child.children.contains(parentID) {
            throw KanbanError.cycleDetected
        }

        parent.children.append(childID)
        child.parents.append(parentID)

        cache[parentID] = parent
        cache[childID] = child
        try save(parent)
        try save(child)
    }

    public func recomputeReady() async throws {
        for var task in cache.values where task.status == .todo {
            let allParentsDone = task.parents.allSatisfy { parentID in
                cache[parentID]?.status == .done
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
        let data = try JSONEncoder().encode(task)
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
}
