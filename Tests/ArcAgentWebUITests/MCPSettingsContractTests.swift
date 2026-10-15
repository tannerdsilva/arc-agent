import Foundation
import Testing

extension ArcWebUITestRoot {
    /// the Settings → MCP servers surface, pinned against the sources (the house
    /// style for wiring contracts that are not reachable as pure units):
    /// - the form's field names are the submit payload keys the engine builds
    ///   (`extractFormData` keys by `name`), so renaming one silently kills Save;
    /// - the per-row buttons carry their server name through `targetId` from the
    ///   `mcp-list` boundary — the id must not sit on the boundary element itself;
    /// - the delete rides the shared confirm dialog as kind `mcp`;
    /// - the handler validates through `MCPRules` instead of an inline gate;
    /// - the panel owns the launch spec, so the write must be a real
    ///   `saveConfig(ArcConfig)` of the `mcp_servers` block (not `AppSettings`).
    ///
    /// the load-bearing one: the webui turn loop dispatches tools straight through
    /// the registry (no `ArcAgent`), so the boot path must bind the shared
    /// `MCPClientManager` to the config — without it `mcp_tool` is inert in the
    /// web UI whatever the file says.
    @Suite("MCP settings contract", .serialized)
    struct MCPSettingsContractTests {

        private static func source(_ name: String) -> String {
            (try? String(contentsOfFile: "Sources/ArcWebUI/\(name)", encoding: .utf8)) ?? ""
        }

        @Test("the form keeps the submit payload field names")
        func formFieldContract() {
            let views = Self.source("Views.swift")
            for field in ["mcp-name-input", "mcp-command-input", "mcp-args-input", "mcp-env-input"] {
                #expect(views.contains("name=\"\(field)\""), "\(field) is a submit payload key")
            }
            #expect(views.contains("id=\"mcp-form\" data-component-id=\"mcp-form\""),
                    "the submit wire registers on the form id")
        }

        @Test("the submit wire reads exactly the fields the form names")
        func submitWireReadsTheFields() {
            let actions = Self.source("Actions.swift")
            for field in ["mcp-name-input", "mcp-command-input", "mcp-args-input", "mcp-env-input"] {
                #expect(actions.contains("event.string(\"\(field)\")"),
                        "the handler must read \(field) from the submit payload")
            }
        }

        @Test("row actions ride targetId from the mcp-list boundary")
        func rowBoundaryContract() {
            let views = Self.source("Views.swift")
            let actions = Self.source("Actions.swift")
            #expect(views.contains("data-component-id=\"mcp-list\""),
                    "rows need a boundary for the engine to route the click through")
            // `data-component-id="mcp-list"` ends in the substring `id="mcp-list"`,
            // so the component attributes are neutralized before asking whether any
            // element really carries that id (an id on the boundary is never
            // reported as targetId — trap 1 of the click-identity contract).
            let withoutComponentAttrs = views.replacingOccurrences(
                of: "data-component-id=\"", with: "data-component-id-")
            #expect(!withoutComponentAttrs.contains("id=\"mcp-list\""),
                    "the boundary element must not carry an id")
            for prefix in ["mcp-test-", "mcp-edit-", "mcp-del-"] {
                #expect(views.contains("btn(\"\(prefix)\\(enc(name))\", \"\""),
                        "\(prefix)<name> must be a control with no component id of its own")
                #expect(actions.contains("tid.hasPrefix(\"\(prefix)\")"), "\(prefix) must be dispatched")
            }
        }

        @Test("the delete rides the shared confirm dialog as kind mcp")
        func deleteUsesSharedConfirm() {
            let actions = Self.source("Actions.swift")
            #expect(actions.contains("kind: \"mcp\""))
            #expect(actions.contains("case \"mcp\":"), "the modal dispatch needs the branch")
            #expect(actions.contains("removeMCPServer(req.id)"))
        }

        @Test("the handler validates through MCPRules")
        func handlerUsesRules() {
            #expect(Self.source("Actions.swift").contains("MCPRules.planEntry("),
                    "name/command/args/env validation must stay in the shared rules, not inline in a wire")
        }

        @Test("the settings panel is reachable from the nav")
        func panelIsLinked() {
            let views = Self.source("Views.swift")
            #expect(views.contains("href=\"#mcp-servers\""), "Settings nav links the section")
            #expect(views.contains("id=\"mcp-servers\""), "Settings renders the section")
            #expect(views.contains("mcpSettingsHTML()"))
        }

        @Test("boot binds the shared client manager to the configured servers")
        func bootBindsManager() {
            // The webui turn loop never constructs ArcAgent, so this is the only
            // thing that points MCPClientManager at `mcp_servers` in this process.
            #expect(Self.source("AppState.swift").contains("await self.configureMCPClients()"),
                    "AppState.init must bind the manager before the first turn")
            let mcp = Self.source("AppState+MCP.swift")
            #expect(mcp.contains("MCPClientManager.shared.configure(arcConfig.mcpServers)"))
        }

        @Test("every config write re-points the live manager")
        func writesRebind() {
            let mcp = Self.source("AppState+MCP.swift")
            #expect(mcp.contains("await configureMCPClients()"),
                    "a saved server must be reachable without a restart")
            #expect(mcp.contains("try saveConfig(raw)"),
                    "the UI must write the ~/.arc/config.json the CLI and gateway read")
        }

        @Test("the tools panel names the server count for the mcp group")
        func toolsPanelAwareness() {
            let views = Self.source("Views.swift")
            #expect(views.contains("arcConfig.mcpServers.count"),
                    "the mcp group's '1 tool' is meaningless without the server count")
            #expect(views.contains("Settings → MCP servers"),
                    "an empty mcp group must point at where servers are added")
        }
    }
}