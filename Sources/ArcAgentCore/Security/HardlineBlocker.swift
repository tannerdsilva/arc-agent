import Foundation

// MARK: - Hardline Blocklist (Phase 1)
//
// Port of Hermes' HARDLINE_PATTERNS: commands so catastrophic they must
// NEVER run via the agent — regardless of approval mode, YOLO, cron, or a
// human pressing "approve". Opting into YOLO trusts the agent with files
// and services, not with wiping the disk or powering the box off.
//
// The list is deliberately tiny — only things with no recovery path:
// filesystem destruction rooted at /, protected system roots, raw block
// device overwrites, kernel shutdown/reboot, fork bomb, kill-all, and
// sudo password guessing. Recoverable-but-costly operations stay in
// SoftDetector where YOLO can pass them.
//
// Every pattern is anchored to a *command position* (the flat _CMDPOS
// start-position class, plus the quote-aware `markCommandStarts` pass in
// ShellLexer.detectionVariants) so quoted data — `--title "block rm -rf /"`,
// `git commit -m "…rm -rf /…"` — can never trip the unconditional floor.

/// Backends hardline applies to. Hardline only matters for backends that can
/// damage the host; a containerized shell cannot. Arc's terminal is local
/// (and ssh via remote hosts), so `.local`/`.ssh` are gated; `.container`
/// is not.
public enum HardlineBackend: String, Sendable {
    case local
    case ssh
    case container

    static func applies(_ backend: HardlineBackend) -> Bool {
        backend != .container
    }
}

enum HardlineBlocker {

    /// The flat command-position anchor: start of string, after a newline
    /// (real separators are converted to newlines by markCommandStarts),
    /// after a backtick or `$(`, with optional sudo/env/exec/nohup/setsid
    /// wrappers consumed. Quoted data can never produce these positions.
    private static let cmdPos =
        #"(?:^|[\n`]|\$\()"# +
        #"\s*"# +
        #"(?:sudo\s+(?:-[^\s]+\s+)*)?"# +
        #"(?:env\s+(?:\w+=\S*\s+)*)?"# +
        #"(?:(?:exec|nohup|setsid|time)\s+)*"# +
        #"\s*"#

    /// Destructive-path argument matcher for the rm hardline rules. Accepts
    /// the path either fully wrapped in a matching quote pair OR bare with a
    /// terminator (whitespace, EOS, or a shell metacharacter) so
    /// `rm -rf "/"` and `$(rm -rf /)` are both caught.
    private static func rmPath(_ pathAlt: String, tail: String = #"(?:\s|$|[)`;|&])"#) -> String {
        #"(?:["'](?:"# + pathAlt + #")["']|(?:"# + pathAlt + #")"# + tail + #")"#
    }

    /// Protected system roots whose recursive deletion has no recovery path.
    private static let hardlineSystemDirs =
        #"/home|/home/\*|/root|/root/\*|/etc|/etc/\*|/usr|/usr/\*|"# +
        #"/var|/var/\*|/bin|/bin/\*|/sbin|/sbin/\*|/boot|/boot/\*|/lib|/lib/\*"#

    /// `rm` plus its flag group, anchored to a command position.
    private static let rmFlagPrefix = cmdPos + #"rm\s+(-[^\s]*\s+)*"#

    // The 12 hardline patterns, verbatim from the reference.
    static let patterns: [(String, String)] = [
        // 1. Recursive delete of the root filesystem. The path alternation
        //    matches any root-anchored spelling that collapses to "/" —
        //    bare "/", "//", "/.", "/..", trailing glob — plus the
        //    slash-space-glob form `rm -rf / *`.
        (rmFlagPrefix + rmPath(#"/(?:(?:\.\.?)?/)*(?:\.\.?)?\**|/ \*"#),
         "recursive delete of root filesystem"),
        // 2. Recursive delete of protected system roots.
        (rmFlagPrefix + rmPath(hardlineSystemDirs),
         "recursive delete of system directory"),
        // 3. Recursive delete of home (~, $HOME, ${HOME}, quoted variants).
        (rmFlagPrefix + rmPath(#"(?:~|\$\{?HOME\}?)(?:/?|/\*)?"#),
         "recursive delete of home directory"),
        // 4. Filesystem format.
        (#"\bmkfs(\.[a-z0-9]+)?\b"#, "format filesystem (mkfs)"),
        // 5-6. Raw block device overwrites.
        (#"\bdd\b[^\n]*\bof=/dev/(sd|nvme|hd|mmcblk|vd|xvd)[a-z0-9]*"#,
         "dd to raw block device"),
        (#">\s*/dev/(sd|nvme|hd|mmcblk|vd|xvd)[a-z0-9]*\b"#,
         "redirect to raw block device"),
        // 7. Fork bomb (classic shell form).
        (#":\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:"#, "fork bomb"),
        // 8. Kill every process on the system.
        (#"\bkill\s+(-[^\s]+\s+)*-1\b"#, "kill all processes"),
        // 9-12. Kernel shutdown/reboot, anchored to command positions so
        // `echo reboot` / `grep 'shutdown' logs` never match.
        (cmdPos + #"(shutdown|reboot|halt|poweroff)\b"#, "system shutdown/reboot"),
        (cmdPos + #"init\s+[06]\b"#, "init 0/6 (shutdown/reboot)"),
        (cmdPos + #"systemctl\s+(poweroff|reboot|halt|kexec)\b"#, "systemctl poweroff/reboot"),
        (cmdPos + #"telinit\s+[06]\b"#, "telinit 0/6 (shutdown/reboot)"),
    ]

    /// Sudo stdin guard: `sudo -S` pipes a guessed password via stdin —
    /// an LLM brute-force vector. Unconditional block (arc never injects
    /// -S itself; there is no configured-sudo-password path to exempt).
    private static let sudoStdin =
        #"(?:^|[;&|`\n]|&&|\|\||\$\()\s*sudo\s+-S\b"#

    /// Detect a hardline command. Returns the human-readable hit description
    /// (the "patternID") or nil. NEVER bypassable — callers must deny without
    /// rendering any approval surface.
    static func detect(_ command: String) -> String? {
        if ShellLexer.parserLimitExceeded(command) {
            return ShellLexer.parserLimitDescription
        }
        let normalized = ShellLexer.normalize(command)
        let (_, malformedGrep) = ShellLexer.grepSafeVariant(normalized)
        if malformedGrep {
            return ShellLexer.malformedExecDescription
        }
        // sudo -S guard, on the normalized lowercased text.
        if let re = compiledSudoStdin {
            let ns = normalized.lowercased() as NSString
            if re.firstMatch(in: normalized.lowercased(), range: NSRange(location: 0, length: ns.length)) != nil {
                return "sudo password guessing via stdin (sudo -S)"
            }
        }
        let store = SecurityRegexStore.shared
        for variant in ShellLexer.detectionVariants(command) {
            let lowered = variant.lowercased()
            if let hit = store.firstHardlineMatch(lowered) {
                return hit
            }
        }
        return nil
    }

    static var compiledSudoStdin: NSRegularExpression? {
        try? NSRegularExpression(pattern: sudoStdin, options: [.caseInsensitive])
    }
}

// MARK: - Compiled-pattern store

/// Owns every compiled detection regex for all three layers.
///
/// Concurrency note: `NSRegularExpression` is an immutable, documented
/// thread-safe class. It is not declared `Sendable` on this toolchain, so
/// the singleton is opt-ed out via `nonisolated(unsafe)` — a documented,
/// narrow exception in the spirit of the Law's accepted workarounds. The
/// store is write-once at process start and read-only afterwards; no
/// mutable state is ever shared.
final class SecurityRegexStore {
    nonisolated(unsafe) static let shared = SecurityRegexStore()

    struct Entry {
        let regex: NSRegularExpression
        let description: String
    }

    private let hardline: [Entry]
    private let soft: [Entry]

    init() {
        let flags: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]
        func compile(_ raw: String, _ description: String) -> Entry? {
            guard let re = try? NSRegularExpression(pattern: raw, options: flags) else {
                // A failed compile is a hole in the floor — fail LOUD in
                // debug, and drop the entry rather than mis-match.
                assertionFailure("Failed to compile detection pattern: \(raw)")
                return nil
            }
            return Entry(regex: re, description: description)
        }
        hardline = HardlineBlocker.patterns.compactMap { compile($0.0, $0.1) }
        soft = SoftDetector.patterns.compactMap { compile($0.0, $0.1) }
    }

    nonisolated func firstHardlineMatch(_ lowered: String) -> String? {
        let ns = lowered as NSString
        let range = NSRange(location: 0, length: ns.length)
        for entry in hardline where entry.regex.firstMatch(in: lowered, range: range) != nil {
            return entry.description
        }
        return nil
    }

    nonisolated func firstSoftMatch(_ lowered: String) -> String? {
        let ns = lowered as NSString
        let range = NSRange(location: 0, length: ns.length)
        for entry in soft where entry.regex.firstMatch(in: lowered, range: range) != nil {
            return entry.description
        }
        return nil
    }
}
