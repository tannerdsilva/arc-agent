import Foundation

/// What arc will and will not launch as an MCP server.
///
/// An MCP server arc can use is a program that already exists on this machine:
/// one executable, launched directly (`exec`, no shell), speaking
/// newline-delimited JSON-RPC on stdio. It is never resolved from a package
/// name, never fetched at launch time, and never interpreted by a package
/// manager — a server that downloads its own code on every start is a
/// dependency the network owns, and arc does not take those.
///
/// The rule is data, not prose: one table here, consulted by the settings form
/// (``MCPRules`` in the web UI) *and* by the spawn path
/// (``MCPClientManager``), so a hand-edited `~/.arc/config.json` cannot walk a
/// refused launcher past the check. Anything this table refuses never reaches
/// `posix_spawn`, whichever door the config came through.
///
/// The boundary is the *launcher*, not the language of the server: an
/// executable built from any source is fine once it is a program on disk, and
/// a build tool (`swift`, `cargo`, `go`) stays allowed because it compiles a
/// checkout that is already present — that is how a Swift MCP server is
/// produced in the first place.
public enum MCPServerLaunchPolicy {

    /// Launchers whose job is to resolve a package over the network and run it.
    ///
    /// The JavaScript and Python families are the complete set MCP servers are
    /// published under today. Build tools are deliberately absent.
    public static let packageManagers: Set<String> = [
        "npm", "npx", "pnpm", "pnpx", "yarn", "yarnpkg", "bun", "bunx",
        "pip", "pip3", "pipx", "uv", "uvx", "poetry", "conda", "mamba", "micromamba",
    ]

    /// Wrappers that run the program named in their own arguments.
    ///
    /// `/usr/bin/env <launcher> …` and `sh -c "<launcher> …"` do not name a
    /// package manager as argv[0], so a check that only reads the command would
    /// let them through.
    public static let wrappers: Set<String> = ["env", "sh", "bash", "zsh", "dash", "ksh"]

    /// The JavaScript package-tree layout. A path inside it is a
    /// package-manager artifact even when the launcher itself is a bare
    /// interpreter.
    public static let installedPackagePathMarker = "/node_modules/"

    /// Why `command` may not be launched, or `nil` when it may.
    ///
    /// Arguments are part of the rule because a wrapper names the real program
    /// there; a direct executable is judged on its own name.
    public static func refusal(
        command: String,
        arguments: [String] = []
    ) -> MCPServerLaunchRefusal? {
        let name = executableName(command)
        if packageManagers.contains(name) { return .packageManager(name) }
        // The installed-package check covers the command itself (a
        // `node_modules/.bin` shim invoked by path) and every argument (a
        // runtime pointed at an installed file).
        if command.contains(installedPackagePathMarker) { return .installedPackage(command) }
        if let path = arguments.first(where: { $0.contains(installedPackagePathMarker) }) {
            return .installedPackage(path)
        }
        guard wrappers.contains(name) else { return nil }
        for argument in arguments {
            for word in argument.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                let candidate = executableName(String(word))
                if packageManagers.contains(candidate) { return .packageManager(candidate) }
            }
        }
        return nil
    }

    /// The lowercased basename of an executable path or `PATH` name.
    ///
    /// `Command` may carry either spelling (`arc`, `/usr/local/bin/arc`), so
    /// the comparison is always made on the basename.
    public static func executableName(_ command: String) -> String {
        var name = command
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        name = name.lowercased()
        return name.hasSuffix(".exe") ? String(name.dropLast(4)) : name
    }
}

/// A launch spec arc refuses to run, with the sentence that explains why.
///
/// Carried as an error value so the refusal is identical whether it came from
/// the settings form, the agent's `mcp_tool`, or a `config.json` written by
/// hand.
public enum MCPServerLaunchRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    /// The launcher resolves and runs a package over the network.
    case packageManager(String)
    /// The argument points inside an installed package tree.
    case installedPackage(String)

    /// A short noun phrase for listings and logs.
    public var summary: String {
        switch self {
        case .packageManager(let name): return "package manager '\(name)'"
        case .installedPackage: return "an installed package path"
        }
    }

    public var description: String {
        switch self {
        case .packageManager(let name):
            return "'\(name)' is a package manager, and arc never launches one as an MCP server. "
                + "Point Command at the server executable instead — a Swift server built with "
                + "swift-mcp, or arc's own, which ships in this binary: command `arc`, "
                + "arguments `tools` `mcp` `serve`."
        case .installedPackage(let path):
            return "'\(path)' lives inside an installed package tree (node_modules). arc launches "
                + "local executables only; a dependency resolved by a package manager is not a "
                + "server it runs."
        }
    }
}
