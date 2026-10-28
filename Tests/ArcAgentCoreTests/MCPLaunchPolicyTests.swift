import Testing
@testable import ArcAgentCore

extension ArcCoreTestRoot {
    /// The launcher policy: arc runs programs that are already on disk, and
    /// never a launcher that resolves a package over the network. These cases
    /// are the contract the settings form and the spawn path both consult, so
    /// no later entry point can quietly reintroduce a package manager.
    @Suite("MCP launch policy", .serialized)
    struct MCPLaunchPolicyTests {

        private static let managers = [
            "npm", "npx", "pnpm", "pnpx", "yarn", "yarnpkg", "bun", "bunx",
            "pip", "pip3", "pipx", "uv", "uvx", "poetry", "conda",
        ]

        @Test("every package-manager launcher is refused by name and by path")
        func refusesByNameAndPath() {
            for manager in Self.managers {
                #expect(MCPServerLaunchPolicy.refusal(command: manager) == .packageManager(manager),
                        "\(manager) must be refused as a bare name")
                #expect(MCPServerLaunchPolicy.refusal(command: "/opt/homebrew/bin/\(manager)")
                        == .packageManager(manager),
                        "\(manager) must be refused as an absolute path")
                #expect(MCPServerLaunchPolicy.refusal(command: "/usr/bin/env",
                                                      arguments: [manager, "-y", "server"])
                        == .packageManager(manager),
                        "env must not smuggle \(manager) past the command field")
            }
        }

        @Test("a shell script that names a package manager is refused")
        func refusesShellScript() {
            #expect(MCPServerLaunchPolicy.refusal(
                command: "/bin/sh", arguments: ["-c", "npx -y some-server"]
            ) == .packageManager("npx"))
            #expect(MCPServerLaunchPolicy.refusal(
                command: "bash", arguments: ["-lc", "/usr/bin/env pnpm dlx some-server"]
            ) == .packageManager("pnpm"))
        }

        @Test("a path inside an installed package tree is refused")
        func refusesInstalledPackagePath() {
            let path = "/usr/local/lib/node_modules/@scope/server/index.js"
            #expect(MCPServerLaunchPolicy.refusal(command: "node", arguments: [path])
                    == .installedPackage(path),
                    "a node_modules artifact is a package-manager dependency whatever launches it")
            let shim = "/Users/you/project/node_modules/.bin/some-server"
            #expect(MCPServerLaunchPolicy.refusal(command: shim) == .installedPackage(shim),
                    "an installed .bin shim invoked by path is still npm's binary")
        }

        @Test("local executables stay allowed, including a Swift build and a script")
        func allowsLocalPrograms() {
            // arc's own server: the canonical zero-install Swift MCP server.
            #expect(MCPServerLaunchPolicy.refusal(command: "arc", arguments: ["tools", "mcp", "serve"]) == nil)
            // a server built with swift-mcp and pointed at directly.
            #expect(MCPServerLaunchPolicy.refusal(command: "/Users/you/.build/release/MCPPack") == nil)
            #expect(MCPServerLaunchPolicy.refusal(command: ".build/debug/MCPFixtureServer", arguments: []) == nil)
            // a build tool compiles a checkout that is already on disk — it is how a
            // Swift server is produced, so it is not a package-manager launcher.
            #expect(MCPServerLaunchPolicy.refusal(command: "swift", arguments: ["run", "-c", "release", "MCPPack"]) == nil)
            // a script on disk is a program, not a package resolution.
            #expect(MCPServerLaunchPolicy.refusal(command: "python3", arguments: ["/Users/you/server.py"]) == nil)
            #expect(MCPServerLaunchPolicy.refusal(command: "/bin/bash", arguments: ["/Users/you/server.sh"]) == nil)
        }

        @Test("the refusal names the launcher and the way out")
        func refusalIsActionable() {
            let refusal = MCPServerLaunchPolicy.refusal(command: "npx")
            #expect(refusal?.description.contains("npx") == true)
            #expect(refusal?.description.contains("package manager") == true)
            #expect(refusal?.description.contains("arc") == true,
                    "the message must point at arc's own Swift server")
        }
    }
}
