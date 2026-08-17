import Foundation

// MARK: - Settings Page

/// The settings page for the ARC Agent web UI.
///
/// Contains configuration options including cronjob management,
/// model settings, and profile configuration.
public struct SettingsPage: View {
    public let profiles: [ProfileData]
    public let selectedBot: String

    public init(
        profiles: [ProfileData] = [],
        selectedBot: String = "default"
    ) {
        self.profiles = profiles
        self.selectedBot = selectedBot
    }

    public func render() -> String {
        return """
        <div class="settings-page">
          <div class="settings-header">
            <a href="/ui/bots" class="nav-tab">← Back to Bots</a>
            <h1>Settings</h1>
          </div>

          <div class="settings-content">
            \(renderCronjobsSection())
            \(renderGeneralSection())
          </div>
        </div>
        """
    }

    private func renderCronjobsSection() -> String {
        return """
        <div class="settings-section">
          <div class="settings-section-header">
            <h2>📅 Cronjobs</h2>
            <button class="btn-primary" onclick="openNewRoutineDialog()">+ New Cronjob</button>
          </div>
          <div class="settings-section-body">
            <div class="empty-state">
              <div class="icon">📅</div>
              <div>Cronjobs are recurring tasks this agent runs on a schedule.</div>
              <button class="btn-secondary" onclick="openNewRoutineDialog()">Create Cronjob</button>
            </div>
          </div>
        </div>
        """
    }

    private func renderGeneralSection() -> String {
        return """
        <div class="settings-section">
          <div class="settings-section-header">
            <h2>⚙️ General</h2>
          </div>
          <div class="settings-section-body">
            <div class="setting-row">
              <div class="setting-label">
                <div class="setting-name">Default Model</div>
                <div class="setting-desc">The model used for new conversations.</div>
              </div>
              <select class="model-select" id="settings-model" onchange="switchModel(this.value)">
                <option value="default">Default</option>
              </select>
            </div>

            <div class="setting-row">
              <div class="setting-label">
                <div class="setting-name">Provider</div>
                <div class="setting-desc">The LLM provider for the default model.</div>
              </div>
              <select class="model-select" id="settings-provider">
                <option value="default">Default</option>
              </select>
            </div>
          </div>
        </div>
        """
    }
}
