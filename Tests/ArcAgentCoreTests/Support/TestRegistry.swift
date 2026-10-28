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
    static func testRegistry(
        profile: ProfileName = .default,
        workspace: String = FileManager.default.currentDirectoryPath,
        profiles: (any ProfileStore)? = nil,
        memory: (any MemoryProvider)? = nil,
        sessions: (any SessionStore)? = nil
    ) throws -> CompileTimeToolRegistry {
        try buildRegistry(
            context: testContext(profile: profile, workspace: workspace),
            profiles: profiles ?? TesseraProfileStore.shared,
            memory: memory ?? FileMemoryProvider(),
            sessions: sessions ?? FileSessionStore()
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
            pluginRegistry: pluginRegistry,
            enabledPlugins: enabledPlugins,
            sources: sources
        )
    }
}
