import ArcAgentCore
import ArcTheme
import WebUI
import WebUIDesignSystem

/// one action offered in a user message's hover footer.
///
/// the surface is closed by the product — copy this message, or fork the
/// conversation at this point into a new session — so the type is an enum
/// rather than an open protocol: rendering stays exhaustive, and an action can
/// never exist that no wire handler answers.
enum MessageAction: Equatable, Sendable {

    /// copy the message's visible text. client-only: the overlay owns the
    /// `[data-copy]` delegate, so this action carries no server identity.
    case copy(text: String)

    /// fork the transcript through this user message into a new session.
    case fork(sessionID: String, messageIndex: Int)

    /// the visible button text.
    var label: String {
        switch self {
        case .copy: "Copy"
        case .fork: "Fork here"
        }
    }

    /// the tooltip and the accessible name. the fork title states the outcome,
    /// not the mechanism: a new chat, continuing from this message.
    var title: String {
        switch self {
        case .copy: "Copy message"
        case .fork: "Start a new chat from this message"
        }
    }

    var icon: IconName {
        switch self {
        case .copy: .copy
        case .fork: .gitBranch
        }
    }

    /// the id the engine reports as `targetId` for this action. nil when the
    /// action never reaches the server.
    var wireID: String? {
        switch self {
        case .copy: nil
        case .fork(let sessionID, let messageIndex):
            "fork-\(enc(sessionID)).\(messageIndex)"
        }
    }

    /// Decode `fork-<session>.<index>` back to its two fields.
    ///
    /// `enc` is base64url, whose alphabet is `A-Z a-z 0-9 - _`; `.` cannot
    /// occur inside it, so the first dot is the field boundary and the session
    /// id never needs escaping a second time.
    static func forkTarget(in wireID: String) -> (sessionID: String, messageIndex: Int)? {
        let prefix = "fork-"
        guard wireID.hasPrefix(prefix) else { return nil }
        let parts = wireID.dropFirst(prefix.count).split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let sessionID = dec(parts[0]),
              let messageIndex = Int(parts[1]),
              messageIndex >= 0 else { return nil }
        return (sessionID, messageIndex)
    }
}

// MARK: - rendering

extension AppState {

    /// The actions a user message offers: copy always; fork only when the
    /// message belongs to a known session and has a stable transcript index.
    ///
    /// A task thread passes no session id on purpose: forking there would swap
    /// the active chat behind a panel that never shows it.
    func userMessageActions(for message: Message, rawIdx: Int, sessionID: String?) -> [MessageAction] {
        var actions: [MessageAction] = [.copy(text: message.displayText ?? message.content ?? "")]
        if let sessionID, !sessionID.isEmpty, rawIdx >= 0 {
            actions.append(.fork(sessionID: sessionID, messageIndex: rawIdx))
        }
        return actions
    }

    /// The hover footer under a user message.
    ///
    /// The row is one event boundary (`msg-actions`); each id-bearing control
    /// inside it reports itself as the engine's `targetId`, which is the shape
    /// `ClickIdentityContractTests` requires (the boundary must be an ancestor,
    /// never the control itself). A row with no server action carries no
    /// boundary at all, so a task thread's copy button routes nowhere.
    func userMessageActionsHTML(_ actions: [MessageAction]) -> some WebUI.View {
        let controls: [any WebUI.View] = actions.map { actionButtonHTML($0) }
        let row = Div(class: .msgFoot) {
            Span(class: .msgActions) {
                controls
            }
        }
        return Group {
            if actions.contains(where: { $0.wireID != nil }) {
                row.wire("msg-actions")
            } else {
                row
            }
        }
    }

    /// One footer control. Copy is a client delegate (`data-copy`); fork is a
    /// server action whose id encodes the session and cut point.
    private func actionButtonHTML(_ action: MessageAction) -> some WebUI.View {
        Group {
            switch action {
            case .copy(let text):
                ArcButton(id: nil, component: nil, class: .msgActionBtn) {
                    WebUIIcon(action.icon, size: .small)
                    // the marker lets the overlay replace the LABEL with
                    // "Copied" instead of the whole button with "✓" — a
                    // labelled control must not collapse its own width.
                    Span { Text(action.label) }
                        .data("copy-label", "")
                }
                .data("copy", text)
                .title(action.title)
                .aria(.label(action.title))
            case .fork:
                ArcButton(id: action.wireID, component: nil, class: .msgActionBtn) {
                    WebUIIcon(action.icon, size: .small)
                    Span { Text(action.label) }
                }
                .title(action.title)
                .aria(.label(action.title))
            }
        }
    }
}
