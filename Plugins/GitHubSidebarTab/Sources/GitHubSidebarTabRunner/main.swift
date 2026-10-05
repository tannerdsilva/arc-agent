import ArcSidebarTabs
import GitHubSidebarTab

// Sidecar entry point: speak the plugin RPC protocol on stdin/stdout
// until the host closes stdin. The host (arc-agent) spawns this binary
// at startup from ~/.arc/plugins/github-sidebar-tab/.
try await SidecarServer.run(plugin: GitHubSidebarTabPlugin())
