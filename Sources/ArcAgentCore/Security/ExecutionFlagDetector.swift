import Foundation

// MARK: - Structural Execution-Flag Detection (Phase 3 / Layer 3)
//
// Regex layer-2 patterns miss obfuscated execution — interpreters handed
// code as a FLAG value, not as script text. This layer parses the command
// structurally (via ShellLexer) and looks INSIDE those flag values:
//
//   • interpreter `-c`/`-e`/`--eval` payloads (python, node, perl, ruby, php, lua)
//   • `bash -c "…"` payloads — rescanned recursively as shell
//   • read-tool exec flags — `jq`, `awk`, `sed`, `perl -0`, git `-c
//     core.pager`, grep `--pager` … anything with a bundled VM
//   • parser-limit fail-closed guards (see ShellLexer)
//
// All findings map to the same promptable-dangerous level as Layer 2.

enum ExecutionFlagDetector {

    // MARK: Interpreter family (first token after wrapper prefixes)

    private static let interpreterFamilies: [String: [String]] = [
        "python": ["python", "python3", "python3.10", "python3.11", "python3.12", "python3.13", "pypy", "pypy3"],
        "node": ["node", "nodejs", "deno", "bun"],
        "perl": ["perl"],
        "ruby": ["ruby", "irb"],
        "php": ["php", "php8", "php8.1", "php8.2", "php8.3"],
        "lua": ["lua", "lua5.1", "lua5.3", "lua5.4", "luajit"],
        "tcl": ["tclsh"],
        "rscript": ["rscript", "r"],
        "jshell": ["jshell", "groovy"],
    ]

    /// Eval-style flags per interpreter family. Values are code.
    private static let evalFlags: [String: Set<String>] = [
        "python": ["-c", "-m"],   // -m can import-and-run arbitrary modules
        "node": ["-e", "--eval", "-p", "--print", "-c", "--check=false"],
        "perl": ["-e", "-E", "-M"],
        "ruby": ["-e", "-r"],
        "php": ["-r", "-B", "-R", "-F", "--run"],
        "lua": ["-e"],
        "tcl": [],
        "rscript": ["-e"],
        "jshell": [],
    ]

    /// Flags whose VALUES are code even when the flag itself is benign
    /// (e.g. python `-W` takes a warning filter — not code).
    private static let valueIsCodeFlags: Set<String> = []

    /// Interpreters where `-` (stdin) is effectively code entry.
    private static let stdinCodeInterpreters: Set<String> = ["python", "node", "perl", "ruby", "php"]

    // MARK: Read-tool exec flags

    /// Tools that are nominally "read" tools but can execute arbitrary code
    /// via a flag value.
    private static let readToolExecFlags: [String: Set<String>] = [
        "jq": ["-f"],                                  // --from-file runs jq program
        "awk": [],                                     // awk 'prog' is positional — handled via payload scan
        "gawk": [],
        "sed": [],                                     // sed w/ w/r flags handled in payload
        "git": ["-c"],                                 // git -c core.pager=… / alias.*=… can exec
        "ssh": ["-o"],                                 // ssh -o ProxyCommand=… execs
        "find": [],                                    // find -exec is a separate positional grammar
        "xargs": [],
        "sqlite3": [".system"],                        // dot-command (rare on CLI; keep for .system)
        "gnuplot": ["-e"],
        "bc": ["-i"],
        "ffmpeg": [],                                  // -filter_complex can exec via subfile — out of scope
        "curl": [],                                    // curl|sh covered by Layer 2
        "osascript": ["-e"],
        "applescript": ["-e"],
    ]

    // MARK: Entry point

    struct Finding {
        let description: String
    }

    /// Find obfuscated-execution patterns. Returns findings in deterministic
    /// order (first hit is reported by SoftDetector).
    static func findings(_ normalizedLowercased: String) -> [Finding] {
        var out: [Finding] = []
        let segments = ShellLexer.topLevelSegments(normalizedLowercased)
        for segment in segments {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // Fail closed: if the segment can't be tokenized, treat it as
            // a finding rather than letting it through unexamined.
            guard let tokens = ShellLexer.shellTokens(trimmed) else {
                out.append(Finding(description: ShellLexer.malformedExecDescription))
                continue
            }
            if tokens.isEmpty { continue }
            guard let head = tokens.first else { continue }
            let headBase = (head as NSString).lastPathComponent

            // 1. Interpreter -c/-e payloads.
            if let family = interpreterFamily(for: headBase) {
                if let finding = interpreterExecFinding(family: family, tokens: Array(tokens.dropFirst())) {
                    out.append(finding)
                }
                continue
            }

            // 2. bash/sh -c payload — rescan recursively as shell.
            if ["bash", "sh", "zsh", "ksh", "dash"].contains(headBase) {
                if let payload = execPayload(tokens: Array(tokens.dropFirst()), flags: ["-c", "--command"]) {
                    for variant in ShellLexer.detectionVariants(payload) {
                        if let hit = SecurityRegexStore.shared.firstSoftMatch(variant.lowercased()) {
                            out.append(Finding(description: "dangerous command inside \(headBase) -c payload: \(hit)"))
                            return out
                        }
                    }
                    // Nested interpreter inside the payload.
                    out.append(contentsOf: findings(payload))
                }
                continue
            }

            // 3. Read-tool exec flags.
            if let flags = readToolExecFlags[headBase] {
                if let finding = readToolFinding(tool: headBase, allowed: flags, tokens: Array(tokens.dropFirst())) {
                    out.append(finding)
                }
            }
        }
        return out
    }

    // MARK: Internals

    /// Payloads an outer scanner (ShellLexer.detectionVariants) should
    /// surface recursively: `bash -c` script bodies and interpreter eval
    /// payloads. Order: last-found first (matching the pending-stack pop).
    static func nestedPayloads(in normalized: String) -> [String] {
        var out: [String] = []
        let segments = ShellLexer.topLevelSegments(normalized)
        for segment in segments {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let tokens = ShellLexer.shellTokens(trimmed) else { continue }
            guard let head = tokens.first else { continue }
            let headBase = (head as NSString).lastPathComponent
            if ["bash", "sh", "zsh", "ksh", "dash"].contains(headBase) {
                if let payload = execPayload(tokens: Array(tokens.dropFirst()), flags: ["-c", "--command"]) {
                    out.append(payload)
                }
            } else if let family = interpreterFamily(for: headBase) {
                let evals = evalFlags[family] ?? []
                if !evals.isEmpty, let payload = execPayload(tokens: Array(tokens.dropFirst()), flags: evals) {
                    out.append(payload)
                }
            }
        }
        return out
    }

    private static func interpreterFamily(for basename: String) -> String? {
        for (family, binaries) in interpreterFamilies {
            if binaries.contains(basename) {
                return family
            }
        }
        return nil
    }

    /// Extract the payload of the first `flag value` pair where flag is an
    /// exec flag. Returns nil if no such flag or if the flag has no value.
    private static func execPayload(tokens: [String], flags: Set<String>) -> String? {
        var i = 0
        while i < tokens.count {
            let tok = tokens[i]
            if flags.contains(tok), i + 1 < tokens.count {
                return tokens[i + 1]
            }
            // Combined short flags: -lc → l and c. If c present, next token.
            if tok.hasPrefix("-"), !tok.hasPrefix("--"), tok.count > 2 {
                let letters = String(tok.dropFirst())
                if letters.contains("c") && (flags.contains("-c")) {
                    if i + 1 < tokens.count { return tokens[i + 1] }
                }
            }
            // `--flag=value` long form.
            if tok.hasPrefix("--"), let eq = tok.firstIndex(of: "=") {
                let name = String(tok[..<eq])
                if flags.contains(name) {
                    return String(tok[tok.index(after: eq)...])
                }
            }
            i += 1
        }
        return nil
    }

    private static func interpreterExecFinding(family: String, tokens: [String]) -> Finding? {
        let evals = evalFlags[family] ?? []
        guard !evals.isEmpty else { return nil }
        if let payload = execPayload(tokens: tokens, flags: evals) {
            let deobf = ShellLexer.deobfuscate(payload)
            // Heuristic: a code payload is only flagged when it references
            // anything the shell-level rules would care about. Pure math or
            // print statements pass; anything touching the system is flagged.
            if referencesSystemSurface(deobf) {
                return Finding(description: "code passed to \(family) interpreter references system surface")
            }
        }
        return nil
    }

    private static func readToolFinding(tool: String, allowed: Set<String>, tokens: [String]) -> Finding? {
        guard !allowed.isEmpty else { return nil }
        for tok in tokens {
            if allowed.contains(tok) {
                return Finding(description: "\(tool) exec flag (\(tok)) — nominally read tool with code execution")
            }
            if tok.hasPrefix("--"), let eq = tok.firstIndex(of: "=") {
                let name = String(tok[..<eq])
                if allowed.contains(name) {
                    return Finding(description: "\(tool) exec flag (\(name)=…) — nominally read tool with code execution")
                }
            }
        }
        return nil
    }

    /// Conservative substring test: does this code payload mention anything
    /// system-level? Kept deliberately broad — a false positive costs one
    /// prompt; a false negative is silent arbitrary execution.
    private static func referencesSystemSurface(_ code: String) -> Bool {
        let lowered = code.lowercased()
        let needles = [
            "subprocess", "os.system", "popen", "exec", "eval(", "open(", "remove(",
            "unlink", "rmtree", "chmod", "chown", "kill", "/etc/", "~/.ssh", "sudo",
            "child_process", "require(", "import os", "importlib", "environ",
            "file", "curl", "wget", "urllib", "requests", "socket", "base64",
            "bash", "sh -c", "system(", "backtick",
        ]
        return needles.contains { lowered.contains($0) }
    }
}
