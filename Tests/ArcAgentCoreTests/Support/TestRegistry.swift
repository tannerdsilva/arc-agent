import Foundation

@testable import ArcAgentCore

// MARK: - Test registry construction
//
// `ArcAgentCore.buildRegistry(context:…)` replaced the parameterless builder in
// GROUNDZERO slice 4: a tool surface cannot be built without saying whose
// surface it is, and each production call site now chooses its scope. The test
// suites overwhelmingly want "the same compiled surface as before, with no
// profile documents involved", so that scope lives here once instead of being
// spelled out at 60 call sites.
//
// This is deliberately *not* a production seam: it lives in the test target,
// where a wrong scope costs a test assertion rather than a wrong write.

extension ArcAgentCore {

    /// The compiled surface at a neutral scope.
    ///
    /// The grant comes from the live gate, exactly as the daemon's does, so a
    /// test that locks `AgentPowers` before building a registry sees a locked
    /// surface.
    ///
    /// `messaging` and `groupChats` default to doubles so the surface stays
    /// **complete**: `send_bot_message` and `send_group_chat` are part of the
    /// compiled tool list every test pins, and a test that is not exercising
    /// delivery should not have to build a session host to see them. A test
    /// that specifically checks register-when-available calls
    /// `buildRegistry` without them.
    static func testRegistry(
        profile: ProfileName = .default,
        workspace: String = FileManager.default.currentDirectoryPath,
        profiles: (any ProfileStore)? = nil,
        memory: (any MemoryProvider)? = nil,
        sessions: (any SessionStore)? = nil,
        messaging: (any BotMessageDelivering)? = nil,
        groupChats: GroupChatManager? = nil,
        kanban: (any KanbanBoard)? = nil,
        dependencies: ToolDependencies = ToolDependencies()
    ) throws -> CompileTimeToolRegistry {
        try buildRegistry(
            context: testContext(profile: profile, workspace: workspace),
            profiles: profiles ?? TesseraProfileStore.shared,
            memory: memory ?? FileMemoryProvider(),
            sessions: sessions ?? FileSessionStore(),
            messaging: messaging ?? CannedReplyMessaging(reply: "ack"),
            groupChats: groupChats ?? GroupChatManager(profileManager: ProfileManager()),
            kanban: kanban,
            dependencies: dependencies
        )
    }

    /// A `ToolContext` for a test that is not exercising scope.
    static func testContext(
        profile: ProfileName = .default,
        sessionID: String = "test",
        workspace: String = FileManager.default.currentDirectoryPath,
        grant: ToolGrant? = nil
    ) -> ToolContext {
        ToolContext(
            profile: profile,
            sessionID: sessionID,
            workspace: workspace,
            grant: grant ?? AgentPowers.grant(profile: profile)
        )
    }

    /// `MutableToolRegistry.make(…)` at the same neutral scope.
    ///
    /// Same two doubles as ``testRegistry(profile:workspace:profiles:memory:sessions:messaging:groupChats:)``:
    /// the compiled tool list is pinned by count in the pluggability tests, so
    /// a surface built here must carry the messaging tools too.
    static func testMutableRegistry(
        pluginRegistry: PluginRegistry? = nil,
        enabledPlugins: Set<String>? = nil,
        sources: [any ToolSource] = []
    ) async throws -> MutableToolRegistry {
        try await MutableToolRegistry.make(
            context: testContext(),
            profiles: TesseraProfileStore.shared,
            memory: FileMemoryProvider(),
            sessions: FileSessionStore(),
            messaging: CannedReplyMessaging(reply: "ack"),
            groupChats: GroupChatManager(profileManager: ProfileManager()),
            pluginRegistry: pluginRegistry,
            enabledPlugins: enabledPlugins,
            sources: sources
        )
    }
}

// MARK: - Messaging doubles

/// A ``BotMessageDelivering`` that answers immediately with a fixed line.
///
/// `BotMessagingService` is an actor and an actor cannot be subclassed, so
/// delivery is doubled at the protocol seam the tool declares rather than by
/// faking the service. Every send is recorded so a test can prove the tool
/// actually called it.
struct CannedReplyMessaging: BotMessageDelivering {

    /// What the peer "says" back.
    let reply: String

    /// The messages the tool handed over, in order.
    let sent: SentLog

    init(reply: String, sent: SentLog = SentLog()) {
        self.reply = reply
        self.sent = sent
    }

    func sendMessageAndWait(
        _ message: BotMessagingService.BotMessage
    ) async -> AsyncThrowingStream<String, Error> {
        await sent.record(message)
        let reply = reply
        return AsyncThrowingStream { continuation in
            continuation.yield(reply)
            continuation.finish()
        }
    }
}

/// A peer that answers far too late: the stream stays open past the tool's
/// bound, which is the "silent peer" the timeout exists for.
struct LateReplyMessaging: BotMessageDelivering {

    /// How long the peer takes. Must exceed the timeout under test.
    let delay: Duration

    func sendMessageAndWait(
        _ message: BotMessagingService.BotMessage
    ) async -> AsyncThrowingStream<String, Error> {
        let delay = delay
        return AsyncThrowingStream { continuation in
            // The task holds the continuation, so the stream stays open until
            // the reply is yielded (or the reader is cancelled).
            Task {
                try? await Task.sleep(for: delay)
                continuation.yield("too late")
                continuation.finish()
            }
        }
    }
}

/// Records what a double was asked to deliver.
actor SentLog {

    private(set) var messages: [BotMessagingService.BotMessage] = []

    func record(_ message: BotMessagingService.BotMessage) {
        messages.append(message)
    }
}
