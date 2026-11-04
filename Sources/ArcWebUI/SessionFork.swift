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

    /// A fork is meaningful only at a user message or an assistant reply: the
    /// kept transcript must end on something a reader can see. Cutting at a
    /// tool row would keep a result whose call is gone; an out-of-range index
    /// is rejected the same way.
    init?(
        session: Session,
        throughMessageAt index: Int,
        title: String,
        workspaceKey: String? = nil,
        categoryID: String? = nil
    ) {
        guard session.messages.indices.contains(index) else { return nil }
        let cut = session.messages[index]
        // a tool-call request is not a reply: its results would be cut away.
        let isCutPoint = cut.role == .user
            || (cut.role == .assistant && (cut.toolCalls ?? []).isEmpty)
        guard isCutPoint else { return nil }
        self.sourceID = session.id
        self.messages = Array(session.messages[...index])
        // One arrow, never a stack of them. Each fork used to prepend another
        // `↳ ` to the SOURCE title, so forking a fork produced `↳ ↳ Count…` and
        // a third fork pushed the actual name out of the row entirely — the
        // arrow ate the title it exists to preserve. Lineage depth already
        // lives in `parentSessionID`; the marker only has to say "branch".
        self.title = "↳ " + trunc(Self.withoutForkMark(title), 60)
        self.model = session.model
        self.provider = session.provider
        self.config = session.config
        self.contextOverrides = session.contextOverrides
        self.workspaceKey = workspaceKey
        self.categoryID = categoryID
    }

    /// `title` with any fork markers already on it stripped.
    ///
    /// A fork's title is derived from its source, so the arrow would compound
    /// (`↳ ↳ ↳ Count…`) and push the name out of the sidebar row. Depth lives
    /// in `parentSessionID`; the visible marker is a single branch glyph.
    static func withoutForkMark(_ title: String) -> String {
        var rest = Substring(title)
        while let first = rest.first, first == "↳" || first == " " {
            rest = rest.dropFirst()
        }
        return String(rest)
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
    /// `throughMessageAt`, then open it.
    ///
    /// Returns the new session's id; nil when the cut is not a user message or
    /// assistant reply, the source is gone, or storage is unavailable. The
    /// source session is untouched — a fork is a branch, never a truncation.
    @discardableResult
    func forkSession(_ id: String, throughMessageAt index: Int) async -> String? {
        guard let store else { return nil }
        await ensureSessionMessages(id)
        guard let source = sessions.first(where: { $0.id == id }),
              let fork = SessionFork(
                session: source,
                throughMessageAt: index,
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
