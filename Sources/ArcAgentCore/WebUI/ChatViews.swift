import Foundation

// MARK: - Chat Page

/// The main chat interface — clean, modern, distraction-free.
///
/// Layout:
/// ```
/// ┌─────────────────────────────────────┐
/// │ Header: logo, model picker, status  │
/// ├─────────────────────────────────────┤
/// │                                     │
/// │  Messages (scrollable)              │
/// │                                     │
/// ├─────────────────────────────────────┤
/// │ Input bar                           │
/// └─────────────────────────────────────┘
/// ```
public struct ChatPage: View {
    public let welcomeMessage: String
    public let modelName: String
    public let models: [String]
    public let activeMode: String

    public init(
        welcomeMessage: String = "How can I help you today?",
        modelName: String = "default",
        models: [String] = [],
        activeMode: String = "chat"
    ) {
        self.welcomeMessage = welcomeMessage
        self.modelName = modelName
        self.models = models
        self.activeMode = activeMode
    }

    public func render() -> String {
        """
        <div class="app-layout">
          \(HeaderView(modelName: modelName, models: models, activeMode: activeMode).render())
          \(MessageContainer(welcomeMessage: welcomeMessage).render())
          \(InputBar().render())
        </div>
        """
    }
}

// MARK: - Header

/// Minimal header bar — just the essentials.
public struct HeaderView: View {
    public let modelName: String
    public let models: [String]
    public let activeMode: String

    public init(modelName: String = "default", models: [String] = [], activeMode: String = "chat") {
        self.modelName = modelName
        self.models = models
        self.activeMode = activeMode
    }

    public func render() -> String {
        let modelOptions = models.map { m in
            let sel = m == modelName ? " selected" : ""
            return "<option value=\"\(htmlEscape(m))\"\(sel)>\(htmlEscape(m))</option>"
        }.joined()

        let chatActive = activeMode == "chat" ? " active" : ""
        let botsActive = activeMode == "bots" ? " active" : ""

        return """
        <header class="chat-header">
          <div class="header-left">
            <span class="header-logo">⚡</span>
            <span class="header-title">ARC Agent</span>
          </div>
          <nav class="header-nav">
            <a href="/ui" class="nav-tab\(chatActive)" data-mode="chat">Chat</a>
            <a href="/ui/bots" class="nav-tab\(botsActive)" data-mode="bots">Bots</a>
          </nav>
          <div class="header-right">
            <span id="conn" class="status-badge off">Disconnected</span>
            <button class="header-btn" id="settings-btn" onclick="toggleSettings()" title="Settings">
              <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
                <path d="M8 10a2 2 0 100-4 2 2 0 000 4z" stroke="currentColor" stroke-width="1.5"/>
                <path d="M13.5 8a5.5 5.5 0 01-.3 1.8l1.2.9-.8 1.4-1.4-.5a5.5 5.5 0 01-1.6.9l-.4 1.5H9.2l-.4-1.5a5.5 5.5 0 01-1.6-.9l-1.4.5-.8-1.4 1.2-.9A5.5 5.5 0 016 8a5.5 5.5 0 01.3-1.8l-1.2-.9.8-1.4 1.4.5a5.5 5.5 0 011.6-.9L9.2 2h1.6l.4 1.5a5.5 5.5 0 011.6.9l1.4-.5.8 1.4-1.2.9A5.5 5.5 0 0113.5 8z" stroke="currentColor" stroke-width="1.5"/>
              </svg>
            </button>
          </div>
        </header>
        """
    }
}

// MARK: - Message Container

/// The scrollable message area with welcome state.
public struct MessageContainer: View {
    public let welcomeMessage: String

    public init(welcomeMessage: String = "") {
        self.welcomeMessage = welcomeMessage
    }

    public func render() -> String {
        """
        <div class="messages-container" id="messages-container">
          <div class="messages-scroll" id="messages">
            \(welcomeMessage.isEmpty ? renderWelcome() : renderWelcomeMessage(welcomeMessage))
          </div>
          <div id="scroll-anchor"></div>
        </div>
        """
    }

    private func renderWelcome() -> String {
        """
        <div class="welcome-screen">
          <div class="welcome-icon">⚡</div>
          <h2 class="welcome-title">ARC Agent</h2>
          <p class="welcome-subtitle">How can I help you today?</p>
          <div class="welcome-suggestions">
            <div class="suggestion-chip" onclick="sendSuggestion('Write a Swift function')">
              <span class="suggestion-icon">⌨️</span>
              Write a Swift function
            </div>
            <div class="suggestion-chip" onclick="sendSuggestion('Explain this concept')">
              <span class="suggestion-icon">📖</span>
              Explain this concept
            </div>
            <div class="suggestion-chip" onclick="sendSuggestion('Debug my code')">
              <span class="suggestion-icon">🔍</span>
              Debug my code
            </div>
            <div class="suggestion-chip" onclick="sendSuggestion('Summarize a webpage')">
              <span class="suggestion-icon">🌐</span>
              Summarize a webpage
            </div>
          </div>
        </div>
        """
    }

    private func renderWelcomeMessage(_ msg: String) -> String {
        MessageBubble(role: "assistant", contentHTML: "<p>\(htmlEscape(msg))</p>", timestamp: nowISO8601()).render()
    }
}

// MARK: - Message Bubble

/// A single message with avatar, content, timestamp, and actions.
public struct MessageBubble: View {
    public let role: String
    public let contentHTML: String
    public let timestamp: String
    public let messageID: String

    public init(role: String, contentHTML: String, timestamp: String = "", messageID: String = "") {
        self.role = role
        self.contentHTML = contentHTML
        self.timestamp = timestamp
        self.messageID = timestamp.isEmpty ? "msg-\(UUID().uuidString.prefix(8))" : messageID
    }

    public func render() -> String {
        let isUser = role == "user"
        let avatarIcon = isUser ? "👤" : "⚡"
        let avatarClass = isUser ? "avatar-user" : "avatar-assistant"

        return """
        <div class="message-row \(role)" id="\(htmlEscape(messageID))">
          <div class="message-avatar \(avatarClass)">\(avatarIcon)</div>
          <div class="message-content">
            <div class="message-header-row">
              <span class="message-role-label">\(isUser ? "You" : "ARC Agent")</span>
              <span class="message-timestamp">\(htmlEscape(formatTimestamp(timestamp)))</span>
            </div>
            <div class="message-bubble">
              <div class="markdown">\(contentHTML)</div>
            </div>
            \(isUser ? "" : renderActions())
          </div>
        </div>
        """
    }

    private func renderActions() -> String {
        """
        <div class="message-actions">
          <button class="action-btn" onclick="copyMessage('\(htmlEscape(messageID))')" title="Copy">
            <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
              <rect x="3" y="3" width="10" height="10" rx="1.5" stroke="currentColor" stroke-width="1.2"/>
              <path d="M1 11V2.5A1.5 1.5 0 012.5 1H11" stroke="currentColor" stroke-width="1.2"/>
            </svg>
          </button>
          <button class="action-btn" onclick="regenerateMessage('\(htmlEscape(messageID))')" title="Regenerate">
            <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
              <path d="M1 7a6 6 0 0111.3-3M13 7a6 6 0 01-11.3 3" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/>
              <path d="M13 1v4h-4M1 13V9h4" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round"/>
            </svg>
          </button>
        </div>
        """
    }
}

// MARK: - Streaming Indicator

/// Animated typing indicator shown while the LLM is generating.
public struct StreamingIndicator: View {
    public init() {}

    public func render() -> String {
        """
        <div class="message-row assistant streaming-row" id="streaming-indicator">
          <div class="message-avatar avatar-assistant">⚡</div>
          <div class="message-content">
            <div class="message-header-row">
              <span class="message-role-label">ARC Agent</span>
            </div>
            <div class="message-bubble streaming-bubble" id="streaming-content">
              <span class="typing-dots">
                <span class="dot"></span>
                <span class="dot"></span>
                <span class="dot"></span>
              </span>
            </div>
          </div>
        </div>
        """
    }
}

// MARK: - Input Bar

/// Clean input bar with auto-resizing textarea and send button.
public struct InputBar: View {
    public let placeholder: String

    public init(placeholder: String = "Type a message...") {
        self.placeholder = placeholder
    }

    public func render() -> String {
        """
        <div class="input-bar">
          <div class="input-container">
            <textarea
              id="message-input"
              class="input-field"
              placeholder="\(htmlEscape(placeholder))"
              rows="1"
              autofocus
            ></textarea>
            <button id="send-button" class="send-btn" onclick="sendMessage()" disabled>
              <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
                <path d="M2 8l12-6-6 12-2-4-4-2z" fill="currentColor"/>
              </svg>
            </button>
          </div>
          <div class="input-hint">Cmd+Enter for new line</div>
        </div>
        """
    }
}

// MARK: - Settings Panel

/// Slide-out settings drawer.
public struct SettingsPanel: View {
    public let isOpen: Bool

    public init(isOpen: Bool = false) {
        self.isOpen = isOpen
    }

    public func render() -> String {
        let display = isOpen ? "flex" : "none"
        return """
        <div class="settings-overlay" id="settings-overlay" style="display: \(display)" onclick="toggleSettings()">
          <div class="settings-panel" id="settings-panel" onclick="event.stopPropagation()">
            <div class="settings-header">
              <h3>Settings</h3>
              <button class="header-btn" onclick="toggleSettings()">
                <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
                  <path d="M4 4l8 8M12 4l-8 8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
                </svg>
              </button>
            </div>
            <div class="settings-body">
              <div class="settings-section">
                <label class="settings-label">Model</label>
                <select class="settings-select" id="settings-model" onchange="switchModel(this.value)">
                  <option value="default">default</option>
                </select>
              </div>
              <div class="settings-section">
                <label class="settings-label">Temperature</label>
                <input type="range" class="settings-slider" id="settings-temp" min="0" max="2" step="0.1" value="0.7">
                <span class="settings-value" id="settings-temp-value">0.7</span>
              </div>
              <div class="settings-section">
                <label class="settings-label">Max Tokens</label>
                <input type="range" class="settings-slider" id="settings-maxtokens" min="256" max="8192" step="256" value="2048">
                <span class="settings-value" id="settings-maxtokens-value">2048</span>
              </div>
              <div class="settings-section">
                <label class="settings-label">
                  <input type="checkbox" id="settings-stream" checked>
                  Stream responses
                </label>
              </div>
            </div>
          </div>
        </div>
        """
    }
}

// MARK: - Helpers

/// Format an ISO8601 timestamp for display.
private func formatTimestamp(_ iso: String) -> String {
    guard !iso.isEmpty else { return "" }
    // The JS side handles formatting; pass through for server-rendered messages
    return iso
}

/// Get current time as ISO8601 string.
private func nowISO8601() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}
