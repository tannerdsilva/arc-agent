import Testing
import ArcAgentCore
import Foundation

// MARK: - Core Library

@Test("core library version is set")
func coreVersion() {
    #expect(ArcAgentCore.version == "0.1.0")
}

// MARK: - Tool Registry

@Test("default registry contains all 5 built-in tools")
func defaultRegistryTools() throws {
    let registry = try ArcAgentCore.buildDefaultRegistry()
    #expect(registry.allTools.count == 5)

    let readFile = registry.lookup(name: "read_file")
    #expect(readFile != nil)
    #expect(readFile?.toolset == "file")
    #expect(readFile?.emoji == "📄")

    let writeFile = registry.lookup(name: "write_file")
    #expect(writeFile != nil)
    #expect(writeFile?.toolset == "file")

    let terminal = registry.lookup(name: "terminal")
    #expect(terminal != nil)
    #expect(terminal?.toolset == "terminal")

    let webSearch = registry.lookup(name: "web_search")
    #expect(webSearch != nil)
    #expect(webSearch?.toolset == "web")

    let webExtract = registry.lookup(name: "web_extract")
    #expect(webExtract != nil)
    #expect(webExtract?.toolset == "web")
}

@Test("lookup returns nil for unknown tool")
func lookupUnknown() throws {
    let registry = try ArcAgentCore.buildDefaultRegistry()
    #expect(registry.lookup(name: "nonexistent") == nil)
}

@Test("duplicate registration throws")
func duplicateRegistration() throws {
    var registry = try ArcAgentCore.buildDefaultRegistry()
    #expect(throws: ToolRegistryError.self) {
        try registry.register(ReadFileTool.entry)
    }
}

// MARK: - JSON Schema

@Test("string schema converts to dictionary")
func stringSchema() {
    let schema = JSONSchema.string(description: "A name", default: "world")
    let dict = schema.asDictionary()
    #expect(dict["type"] as? String == "string")
    #expect(dict["description"] as? String == "A name")
    #expect(dict["default"] as? String == "world")
}

@Test("object schema includes required fields")
func objectSchema() {
    let schema = JSONSchema.object(
        description: "A person",
        properties: [
            "name": .string(description: "Full name"),
            "age": .integer(description: "Age in years"),
        ],
        required: ["name"]
    )
    let dict = schema.asDictionary()
    #expect(dict["type"] as? String == "object")
    #expect(dict["required"] as? [String] == ["name"])

    let props = dict["properties"] as? [String: [String: Any]]
    #expect(props?["name"]?["type"] as? String == "string")
    #expect(props?["age"]?["type"] as? String == "integer")
}

@Test("schema building filters by toolset")
func schemaFiltering() throws {
    let registry = try ArcAgentCore.buildDefaultRegistry()

    let schemas = registry.buildToolSchemas(enabled: ["file"], disabled: [])
    #expect(schemas.count == 2)
    #expect(schemas[0]["type"] as? String == "function")

    let webSchemas = registry.buildToolSchemas(enabled: ["web"], disabled: [])
    #expect(webSchemas.count == 2)  // web_search + web_extract

    let disabled = registry.buildToolSchemas(enabled: [], disabled: ["file"])
    #expect(disabled.count == 3)  // terminal + web tools remain
}

// MARK: - ToolEntry

@Test("tool entry properties are accessible")
func toolEntryProperties() {
    let entry = ToolEntry(
        name: "test_tool",
        toolset: "test",
        description: "A test tool",
        schema: .string(description: "A param"),
        handler: { _ in "done" },
        emoji: "🧪"
    )
    #expect(entry.name == "test_tool")
    #expect(entry.toolset == "test")
    #expect(entry.description == "A test tool")
    #expect(entry.emoji == "🧪")
    #expect(entry.requiresEnv.isEmpty)
    #expect(entry.checkFn == nil)
}

// MARK: - Message Models

@Test("message creation and properties")
func messageCreation() {
    let msg = Message(role: .user, content: "Hello")
    #expect(msg.role == .user)
    #expect(msg.content == "Hello")
    #expect(msg.toolCalls == nil)
    #expect(msg.toolCallID == nil)
}

@Test("tool call creation")
func toolCallCreation() {
    let tc = ToolCall(
        id: "call_123",
        function: ToolCallFunction(name: "read_file", arguments: "{\"path\": \"/tmp/test\"}")
    )
    #expect(tc.id == "call_123")
    #expect(tc.function.name == "read_file")
    #expect(tc.function.arguments == "{\"path\": \"/tmp/test\"}")
}

// MARK: - Session Store

@Test("file session store CRUD")
func sessionStoreCRUD() async throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("arc-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let store = FileSessionStore(directory: tempDir)
    let session = Session(id: "test-1", model: "gpt-4o", provider: "openai")

    // Create
    try await store.create(session)

    // Read
    let fetched = try await store.get(id: "test-1")
    #expect(fetched != nil)
    #expect(fetched?.model == "gpt-4o")

    // Append message
    try await store.appendMessage(
        sessionID: "test-1",
        message: Message(role: .user, content: "Hello")
    )
    let updated = try await store.get(id: "test-1")
    #expect(updated?.messages.count == 1)
    #expect(updated?.messages.first?.content == "Hello")

    // List
    let sessions = try await store.list(limit: 10)
    #expect(sessions.count == 1)

    // Delete
    try await store.delete(id: "test-1")
    let deleted = try await store.get(id: "test-1")
    #expect(deleted == nil)
}

// MARK: - LLM Client

@Test("LLM error descriptions are informative")
func llmErrorDescriptions() {
    #expect(LLMError.apiError(statusCode: 404, message: "Not found").description.contains("404"))
    #expect(LLMError.rateLimited(retryAfter: 30).description.contains("30"))
    #expect(LLMError.authenticationFailed.description.contains("API key"))
    #expect(LLMError.modelNotFound("gpt-5").description.contains("gpt-5"))
    #expect(LLMError.timeout(30).description.contains("30"))
    #expect(LLMError.decodingError("bad json").description.contains("bad json"))
}

// MARK: - CLI Tools Command

@Test("tools command output includes all 5 tools")
func toolsCommand() throws {
    let registry = try ArcAgentCore.buildDefaultRegistry()
    let names = registry.allTools.map(\.name).sorted()
    #expect(names == ["read_file", "terminal", "web_extract", "web_search", "write_file"])
}
