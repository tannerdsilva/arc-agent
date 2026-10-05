import ArcAgentCore
import ArcSidebarTabs
import Foundation
import Logging
import ServiceLifecycle

// MARK: - Sidecar plugin manager (host side)
//
// Discovers installed sidecar plugins from `~/.arc/plugins/<name>/`
// (manifest.json + executable), spawns each process, handshakes via
// `listTabs`, and hands the resulting `SidebarTabPlugin` facades to the
// application. Every connection is torn down by `shutdown()` (called by
// `SidecarPluginService` on graceful daemon stop), so no plugin process
// outlives the host.
//
// A user "installs" a plugin by copying the plugin's directory (binary +
// manifest.json) into `~/.arc/plugins/`. No rebuild, no source access.

// MARK: - Manifest

/// `manifest.json` of an installed sidecar plugin.
public struct SidecarPluginManifest: Codable, Sendable, Equatable {
    public var name: String? = nil
    public var version: String? = nil
    public var description: String? = nil
    /// Executable file name inside the plugin directory; defaults to the
    /// manifest name when omitted.
    public var executable: String? = nil

    public init(
        name: String,
        version: String = "0.0.0",
        description: String = "",
        executable: String? = nil
    ) {
        self.name = name
        self.version = version
        self.description = description
        self.executable = executable
    }
}

// MARK: - Manager

/// Owns the sidecar plugin processes: discovery, lifecycle, and the
/// host-side channel for their `SidebarTabHost` requests.
public actor SidecarPluginManager {

    /// Test seam: overrides the plugins root (never touches the real
    /// `~/.arc/plugins`).
    public nonisolated(unsafe) static var testPluginsRoot: String?

    public static var pluginsRoot: URL {
        if let override = testPluginsRoot, !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arc/plugins", isDirectory: true)
    }

    private var connections: [SidecarConnection] = []
    private weak var host: AppState?
    private let logger = Logger(label: "arc-agent.sidecar-plugins")

    public init() {}

    /// Attach the application state the sidecars' host-side requests
    /// (workspace path, toasts, navigation) route to. Called by
    /// `WebUIHost.run()` once the app state boots; internal because only
    /// the host reaches into the manager this way.
    func attachHost(_ state: AppState?) {
        host = state
    }

    /// Scan the plugins root and start every valid plugin. An invalid
    /// manifest, missing binary, or failed handshake logs a warning and
    /// skips that plugin — a bad plugin never blocks the boot.
    public func discover() async -> [any SidebarTabPlugin] {
        let fm = FileManager.default
        let root = Self.pluginsRoot
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }

        var plugins: [SidebarTabPlugin] = []
        for dir in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue
            }
            let manifestURL = dir.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(SidecarPluginManifest.self, from: data),
                  let name = manifest.name, !name.isEmpty
            else {
                logger.warning("sidecar directory skipped (no valid manifest.json): \(dir.lastPathComponent)")
                continue
            }
            let binName = manifest.executable ?? name
            let binary = dir.appendingPathComponent(binName).path

            let connection = SidecarConnection(
                binary: binary,
                hostHandler: { [weak self] method, params in
                    guard let reply = try await self?.handleHostRequest(method, params) else {
                        throw SidecarHostError.notAvailable
                    }
                    return reply
                },
                logger: logger
            )
            do {
                try await connection.connect()
                guard case .array(let tabValues) = try await connection.call(SidecarMethod.listTabs)
                else {
                    await connection.disconnect()
                    logger.warning("sidecar plugin '\(name)' returned no tabs; skipped")
                    continue
                }
                let descriptors: [SidecarTabDescriptor] = tabValues.compactMap(Self.decodeDescriptor)
                if descriptors.isEmpty {
                    await connection.disconnect()
                    logger.warning("sidecar plugin '\(name)' has no tab descriptors; skipped")
                    continue
                }
                connections.append(connection)
                plugins.append(SidecarPluginClient(
                    name: name,
                    version: manifest.version ?? "0.0.0",
                    description: manifest.description ?? "",
                    connection: connection,
                    tabs: descriptors
                ))
                logger.info("sidecar plugin loaded: \(name) v\(manifest.version ?? "0.0.0") (\(descriptors.count) tab(s)) from \(binary)")
            } catch {
                await connection.disconnect()
                logger.warning("sidecar plugin '\(name)' failed to start: \(error)")
            }
        }
        return plugins
    }

    /// Terminate every plugin process. Idempotent.
    public func shutdown() async {
        for connection in connections {
            await connection.disconnect()
        }
        connections.removeAll()
    }

    /// The number of live plugin processes (diagnostics).
    public var liveCount: Int { connections.count }

    // MARK: Host-side channel

    private enum SidecarHostError: Error {
        case notAvailable
    }

    /// Answer a plugin→host request. The sidecar's `SidebarTabHost` calls
    /// land here.
    private func handleHostRequest(_ method: String, _ params: SidecarValue?) async throws -> SidecarValue {
        guard let host else { throw SidecarHostError.notAvailable }
        let hostChannel = AppSidebarTabHost(state: host)
        switch method {
        case SidecarMethod.hostWorkspacePath:
            return .string(await hostChannel.workspacePath())
        case SidecarMethod.hostToast:
            let message = params?.key("message")?.string ?? ""
            await hostChannel.toast(message)
            return .null
        case SidecarMethod.hostNavigate:
            if let tab = params?.key("tab")?.string {
                await hostChannel.navigate(to: tab)
            }
            return .null
        case SidecarMethod.hostRefreshTab:
            if let tab = params?.key("tab")?.string {
                await hostChannel.refreshTab(tab)
            }
            return .null
        default:
            throw SidecarHostError.notAvailable
        }
    }

    /// Decode one tab descriptor from its wire object (internal so tests
    /// can pin the wire shape).
    static func decodeDescriptor(_ value: SidecarValue) -> SidecarTabDescriptor? {
        guard let obj = value.object,
              let id = obj["id"]?.string,
              let kind = obj["iconKind"]?.string else { return nil }
        return SidecarTabDescriptor(
            id: id,
            title: obj["title"]?.string ?? id,
            tooltip: obj["tooltip"]?.string ?? id,
            iconKind: kind,
            iconA: obj["iconA"]?.string ?? "",
            iconB: obj["iconB"]?.string ?? ""
        )
    }
}

// MARK: - Service

/// Lifecycle wrapper: keeps the sidecar manager alive while the daemon
/// runs and tears all plugin processes down on graceful shutdown.
public struct SidecarPluginService: Service {
    let manager: SidecarPluginManager

    public init(manager: SidecarPluginManager) {
        self.manager = manager
    }

    public func run() async throws {
        // The group's graceful shutdown cancels this task; the loop exits
        // and the manager disconnects every plugin process (same
        // runUntilShutdown pattern as CronScheduler).
        try await runUntilShutdown { [manager] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        await manager.shutdown()
    }
}
