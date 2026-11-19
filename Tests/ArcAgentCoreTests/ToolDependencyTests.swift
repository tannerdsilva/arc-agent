import Foundation
import Testing

@testable import ArcAgentCore

extension ArcCoreTestRoot {
    /// GROUNDZERO slice 6: a tool surface owns its dependencies.
    ///
    /// Before this suite, every late-bound tool dependency lived in a
    /// `nonisolated(unsafe) static var`: the agent created the resource after
    /// the registry existed and then pointed the tool at it by assigning the
    /// process global. Two `ArcAgent`s in one daemon process therefore shared
    /// one pointer, and the last surface to start won — agent A's `todo` tool
    /// answered out of agent B's list.
    ///
    /// These tests build two surfaces with *different* resources and assert
    /// that neither can observe the other's.
    @Suite("Tool dependencies")
    struct ToolDependencyTests {

        /// A board that keeps its tasks in memory, so two of them are
        /// distinguishable by what they contain.
        private actor MemoryBoard: KanbanBoard {
            private var tasks: [KanbanTask] = []

            func create(_ task: KanbanTask) async throws { tasks.append(task) }
            func get(id: String) async throws -> KanbanTask? { tasks.first { $0.id == id } }
            func update(_ task: KanbanTask) async throws {
                if let i = tasks.firstIndex(where: { $0.id == task.id }) { tasks[i] = task }
            }
            func delete(id: String) async throws { tasks.removeAll { $0.id == id } }
            func list(status: TaskStatus?, assignee: String?, limit: Int) async throws -> [KanbanTask] {
                let filtered = tasks.filter { status == nil || $0.status == status }
                return Array(filtered.prefix(limit))
            }
            func transition(id: String, to newStatus: TaskStatus) async throws {
                guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
                tasks[i].status = newStatus
            }
            func addDependency(parentID: String, childID: String) async throws {}
            func recomputeReady() async throws {}
        }

        private func tool(_ registry: CompileTimeToolRegistry, _ name: String) throws -> any AgentTool {
            try #require(registry.lookup(name: name)).tool
        }

        /// The defect, at the level a second agent in the same process sees it:
        /// surface A's `todo` tool must keep acting on A's list after surface B
        /// is wired with its own.
        @Test("two agents do not share tool state")
        func twoAgentsDoNotShareToolState() async throws {
            let storeA = TodoStore()
            let storeB = TodoStore()

            // Two surfaces, each wired with its own store — the shape an agent
            // uses: the registry exists first, the resource is bound after.
            let depsA = ToolDependencies()
            depsA.todoStore.set(storeA)
            let surfaceA = try ArcAgentCore.testRegistry(dependencies: depsA)
            let depsB = ToolDependencies()
            depsB.todoStore.set(storeB)
            let surfaceB = try ArcAgentCore.testRegistry(dependencies: depsB)

            // A writes through its own tool.
            _ = try await tool(surfaceA, "todo").handler([
                "todos": [["id": "a1", "content": "A only", "status": "pending"]],
                "merge": false,
            ])

            // B's list is B's: it never sees A's item.
            let readB = try await tool(surfaceB, "todo").handler([:])
            #expect(!readB.contains("A only"), "surface B observed surface A's todo list: \(readB)")

            // And A's tool still acts on A's store — this is the assertion the
            // process global breaks, because wiring B re-pointed A's tool too.
            let readA = try await tool(surfaceA, "todo").handler([:])
            #expect(readA.contains("A only"), "surface A lost its own todo list: \(readA)")
            #expect(await storeA.read().count == 1)
            #expect(await storeB.read().isEmpty)
        }

        /// The same shape for kanban, at the layer the unified `kanban` tool
        /// actually isolates on: board namespaces. Two agents (or two boards
        /// on one store) must never observe each other's tasks.
        @Test("two boards do not share tasks")
        func twoBoardsDoNotShareTasks() async throws {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("board-iso-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let store = FileCardStore(arcHome: tmp)

            _ = try await store.createTask(CardTask(title: "A task"), board: "a")
            let listB = try await store.listTasks(board: "b", filter: CardListFilter())
            #expect(listB.isEmpty, "board b observed board a's task")
            let listA = try await store.listTasks(board: "a", filter: CardListFilter())
            #expect(listA.count == 1 && listA.first?.title == "A task", "board a lost its own task")
        }

        /// The other half of the invariant: a *real* agent fills the slots its
        /// surface reads, with resources it owns. Two agents therefore end up
        /// with two different todo stores, and a call through A's tool mutates
        /// A's store — never B's.
        @Test("each agent fills the slots its own surface reads")
        func agentFillsItsOwnSlots() async throws {
            func makeAgent() throws -> (ToolDependencies, CompileTimeToolRegistry, ArcAgent) {
                let deps = ToolDependencies()
                let registry = try ArcAgentCore.testRegistry(dependencies: deps)
                let config = ArcAgent.Configuration(
                    model: "test-model",
                    provider: "openai",
                    baseURL: URL(string: "https://api.openai.com/v1")!,
                    apiKey: "sk-test",
                    registry: registry,
                    sessionStore: VolatileSessionStore(),
                    memoryProvider: nil,
                    persistSessions: false
                )
                return (deps, registry, ArcAgent(config: config))
            }

            let (depsA, surfaceA, _) = try makeAgent()
            let (depsB, surfaceB, _) = try makeAgent()

            let storeA = try #require(depsA.todoStore.get(), "agent A never filled its todo slot")
            let storeB = try #require(depsB.todoStore.get(), "agent B never filled its todo slot")
            #expect(storeA !== storeB, "two agents shared one todo store")
            #expect(depsA.delegationManager.get() != nil)
            #expect(depsB.delegationManager.get() != nil)
            #expect(depsA.delegationManager.get() !== depsB.delegationManager.get())

            _ = try await tool(surfaceA, "todo").handler([
                "todos": [["id": "a1", "content": "A only", "status": "pending"]],
                "merge": false,
            ])
            #expect(await storeA.read().count == 1, "A's tool wrote outside A's store")
            #expect(await storeB.read().isEmpty, "A's tool wrote into B's store")

            let readB = try await tool(surfaceB, "todo").handler([:])
            #expect(!readB.contains("A only"))
        }
    }
}
