import ArcAgentCore
import Foundation

/// The pure plan behind “fork here”: the new session a fork creates, its title,
/// and its lineage.
///
/// A failable value rather than a method body so the two rules that make a fork
/// coherent — the cut point is a user message, and the kept transcript is a
/// prefix inclusive of it — are testable with no store, clock, or view.
struct SessionFork {

    /// the session the fork branched from.
    let sourceID: String

    /// the messages the fork keeps, in order, ending with the cut message.
    let messages: [Message]

    /// the title the sidebar shows for the fork. the arrow reads as a branch
    /// in the chat list without hiding the source conversation's name.
    let title: String

    let model: String
    let provider: String
    /// a pinned per-session config (shared sessions) and context overrides are
    /// part of "continue this conversation": the fork must not fall back to the
    /// local default when the source was pinned.
    let config: SessionConfigSnapshot?
    let contextOverrides: ContextRecipe?
    let workspaceKey: String?
    let categoryID: String?

    /// A fork is only meaningful at a user message: cutting at an assistant or
    /// tool row would replay a reply whose prompt is gone (or a tool result
    /// whose call is gone). Out-of-range indexes are rejected the same way.
    init?(
        session: Session,
        throughUserMessageAt index: Int,
        title: String,
        workspaceKey: String? = nil,
        categoryID: String? = nil
    ) {
        guard session.messages.indices.contains(index),
              session.messages[index].role == .user else { return nil }
        self.sourceID = session.id
        self.messages = Array(session.messages[...index])
        self.title = "↳ " + trunc(title, 60)
        self.model = session.model
        self.provider = session.provider
        self.config = session.config
        self.contextOverrides = session.contextOverrides
        self.workspaceKey = workspaceKey
        self.categoryID = categoryID
    }

    /// Materialize the persisted session. `parentSessionID` records the lineage
    /// so a fork is never mistaken for an unrelated chat.
    func makeSession(now: Date = Date()) -> Session {
        Session(
            id: UUID().uuidString,
            createdAt: now,
            updatedAt: now,
            model: model,
            provider: provider,
            messageCount: messages.count,
            messages: messages,
            parentSessionID: sourceID,
            workspaceKey: workspaceKey,
            config: config,
            contextOverrides: contextOverrides
        )
    }
}

// MARK: - AppState

extension AppState {

    /// Fork `id` into a new session that keeps its transcript through
    /// `throughUserMessageAt`, then open it.
    ///
    /// Returns the new session's id; nil when the index is not a user message,
    /// the source is gone, or storage is unavailable. The source session is
    /// untouched — a fork is a branch, never a truncation.
    @discardableResult
    func forkSession(_ id: String, throughUserMessageAt index: Int) async -> String? {
        guard let store else { return nil }
        await ensureSessionMessages(id)
        guard let source = sessions.first(where: { $0.id == id }),
              let fork = SessionFork(
                session: source,
                throughUserMessageAt: index,
                title: sessionTitle(source),
                workspaceKey: settings.sessionWorkspaces[id],
                categoryID: settings.sessionCategories[id]
              ) else { return nil }

        let copy = fork.makeSession()
        do {
            try await store.create(copy)
        } catch {
            LogCollector.shared.append(
                level: .error,
                text: "[store] fork failed for \(String(id.prefix(8))): \(error)"
            )
            return nil
        }
        settings.sessionTitles[copy.id] = fork.title
        if let workspaceKey = fork.workspaceKey {
            settings.sessionWorkspaces[copy.id] = workspaceKey
        }
        if let categoryID = fork.categoryID {
            settings.sessionCategories[copy.id] = categoryID
        }
        saveSettings()
        await reloadSessions(selecting: copy.id)
        await setActiveSession(copy.id)
        _ = hint("Forked into a new chat from this message.")
        return copy.id
    }
}
