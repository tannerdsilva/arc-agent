import Foundation

/// The single door to `config.json`.
///
/// `ConfigurationStore` is ``DocumentStore`` specialised to ``ArcConfig``: the
/// guarantees (one write path, no silent clobber, declared vs resolved, one
/// generation of backup) live in the generic store. This file adds only what is
/// specific to a configuration file — environment resolution through
/// `applyEnvironmentOverrides` and a write that splits secrets into `.env`.
///
/// `~/.arc/config.json` is resolved through ``ArcHome``, so a second instance
/// (`ARC_HOME=/srv/arc-b`) reads and writes its own file.
public typealias ConfigurationStore = DocumentStore<ArcConfig>

/// The process-wide store, built once per process (a static stored property
/// cannot live in a constrained extension).
private enum ConfigurationStoreShared {
    static let instance = ConfigurationStore()
}

extension DocumentStore where Document == ArcConfig {

    /// The process-wide store.
    public static var shared: ConfigurationStore { ConfigurationStoreShared.instance }

    /// - Parameters:
    ///   - url: the config file. Defaults to ``ArcHome/config``.
    ///   - environment: the environment overrides are read from. Injected so
    ///     tests never depend on the ambient process environment.
    public init(
        url: URL = ArcHome.config,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.init(
            url: url,
            environment: environment,
            resolve: { config, environment in
                ConfigurationStore.resolve(config, environment: environment, url: url)
            },
            write: { config, destination in
                try ConfigurationStore.write(config, to: destination)
            }
        )
    }

    // MARK: - Pure file helpers (shared with `loadConfig` / `saveConfig`)

    /// Read and decode the declared configuration.
    ///
    /// A missing file is an empty declaration (compiled defaults); a file that
    /// exists but does not decode is a ``ConfigError/parseError`` — never a
    /// silent fall back to defaults.
    public static func readDeclared(_ url: URL) throws -> ArcConfig {
        try read(url)
    }

    /// Write the declared configuration, with secrets split into `.env`.
    ///
    /// Keeps one generation of backup first; `saveConfig` still refuses to
    /// overwrite a file that cannot be decoded.
    public static func write(_ config: ArcConfig, to url: URL) throws {
        try backup(at: url)
        try saveConfig(config, to: url)
    }

    /// Apply environment overrides to a declared configuration.
    public static func resolve(
        _ config: ArcConfig,
        environment: [String: String],
        url: URL
    ) -> ArcConfig {
        let dotenv = loadDotEnv(url.deletingLastPathComponent().appendingPathComponent(".env"))
        return applyEnvironmentOverrides(config, environment: environment, dotenv: dotenv)
    }
}
