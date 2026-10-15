import ArcAgentCore
import Foundation

/// MCP server presets (Settings → MCP servers).
///
/// The UI owns the `mcp_servers` block of `~/.arc/config.json` — the same
/// block the CLI (`arc mcp list`) and the daemon read — and keeps the live
/// `MCPClientManager` in step with it.
///
/// That second half is load-bearing. The manager is process-wide and its
/// clients are real MCP server child processes, so a server added or edited
/// here is unreachable until the manager is re-pointed: the webui turn loop
/// dispatches tools straight through the registry (no `ArcAgent`), so nothing
/// else in this process would call `configure` for it.
extension AppState {

    // MARK: Config ↔ manager

    /// Server names in display order.
    func mcpServerNames() -> [String] { arcConfig.mcpServers.keys.sorted() }

    /// The stored launch config for one server, if any.
    func mcpServerConfig(_ name: String) -> MCPServerConfig? { arcConfig.mcpServers[name] }

    /// Bind the shared client manager to the configured servers. Called once at
    /// boot and after every edit, so the config file and the running children
    /// never drift.
    func configureMCPClients() async {
        await MCPClientManager.shared.configure(arcConfig.mcpServers)
    }

    /// Mutate the `mcp_servers` block: persist it to `~/.arc/config.json`,
    /// refresh the in-memory copy, then re-point the live manager (which stops
    /// the children whose config changed and drops the removed servers).
    ///
    /// A save failure leaves the stored config untouched — the form stays open
    /// with the user's text so the edit is not lost.
    @discardableResult
    func updateMCPServers(_ mutate: (inout [String: MCPServerConfig]) -> Void) async -> Bool {
        var raw = Self.rawArcConfig()
        mutate(&raw.mcpServers)
        do {
            try saveConfig(raw)
        } catch {
            hint("Could not save MCP servers: \(error)", kind: "error")
            return false
        }
        arcConfig = raw
        await configureMCPClients()
        return true
    }

    /// Add or replace one server. `previousName` is the name an edit started
    /// from: a rename removes the old key, so the old client is stopped rather
    /// than left running under the old name.
    func upsertMCPServer(name: String, config: MCPServerConfig, previousName: String?) async {
        let renamed = previousName.flatMap { $0 == name ? nil : $0 }
        let ok = await updateMCPServers { servers in
            if let renamed { servers.removeValue(forKey: renamed) }
            servers[name] = config
        }
        guard ok else { return }
        // The old probe described the old process.
        for key in [name, renamed].compactMap({ $0 }) {
            mcpToolCatalog[key] = nil
            mcpTestError[key] = nil
        }
    }

    /// Remove one server (the confirm dialog's target).
    func removeMCPServer(_ name: String) async {
        let ok = await updateMCPServers { $0.removeValue(forKey: name) }
        guard ok else { return }
        mcpToolCatalog[name] = nil
        mcpTestError[name] = nil
    }

    /// Probe one server: start it if needed, list the tools it exposes, and
    /// record the outcome for its row. This is the only way to see a server's
    /// tool names before the agent tries to call one.
    func testMCPServer(_ name: String) async {
        mcpToolCatalog[name] = nil
        mcpTestError[name] = nil
        do {
            let tools = try await MCPClientManager.shared.tools(named: name)
            mcpToolCatalog[name] = tools.map(\.name)
            hint(tools.isEmpty
                 ? "MCP server '\(name)' started but exposes no tools."
                 : "MCP server '\(name)' exposes \(tools.count) tool\(tools.count == 1 ? "" : "s").")
        } catch {
            let text = String(describing: error)
            mcpTestError[name] = text
            hint("MCP server '\(name)' failed: \(text)", kind: "error")
        }
    }

    // MARK: Add / edit form

    /// Open the form for a new server.
    func openMCPAdd() {
        editingMCPServer = nil
        addingMCPServer = true
        clearMCPForm()
    }

    /// Open the form pre-filled from an existing server.
    func openMCPEdit(_ name: String) {
        addingMCPServer = true
        editingMCPServer = name
        let cfg = arcConfig.mcpServers[name]
        formValues["mcp-name-input"] = name
        formValues["mcp-command-input"] = cfg?.command ?? ""
        formValues["mcp-args-input"] = (cfg?.args ?? []).joined(separator: "\n")
        formValues["mcp-env-input"] = (cfg?.env ?? [:])
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
    }

    func closeMCPForm() {
        addingMCPServer = false
        editingMCPServer = nil
        clearMCPForm()
    }

    /// Drop the form drafts (after a successful save, or when opening).
    func clearMCPForm() {
        formValues["mcp-name-input"] = ""
        formValues["mcp-command-input"] = ""
        formValues["mcp-args-input"] = ""
        formValues["mcp-env-input"] = ""
    }

    /// Re-render exactly what was submitted, so a rejected save keeps the
    /// user's text (the debounced input wire may lag the submit frame).
    func storeMCPFormValues(name: String, command: String, argsText: String, envText: String) {
        formValues["mcp-name-input"] = name
        formValues["mcp-command-input"] = command
        formValues["mcp-args-input"] = argsText
        formValues["mcp-env-input"] = envText
    }
}