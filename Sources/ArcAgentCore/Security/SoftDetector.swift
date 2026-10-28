import Foundation

// MARK: - Soft Dangerous-Command Detection (Phase 2 / Layer 2)
//
// Verbatim port of Hermes' DANGEROUS_PATTERNS (77 entries) plus the shared
// path fragments. Flagged commands are *promptable dangerous* — they are
// subject to the approval mode: YOLO (.off) passes them, smart arbitrates
// via the aux classifier, manual prompts. Hardline (HardlineBlocker) sits
// above this layer and is never bypassable.
//
// Hermes-specific rules are remapped to arc's surface (~/.arc/config.json,
// `arc serve`/`arc-agent`) rather than dropped, per the hardening plan.

enum SoftDetector {

    // MARK: Shared path fragments (ported verbatim, hermes→arc remapped)

    static let sshSensitivePath = #"(?:~|\$home|\$\{home\})/\.ssh(?:/|$)"#

    /// ~/.arc/.env — arc's auxiliary-credential file.
    static let arcEnvPath =
        #"(?:~/\.arc/|(?:\$home|\$\{home\})/\.arc/|(?:\$arc_home|\$\{arc_home\})/)"# +
        #"\.env\b"#

    /// ~/.arc/config.json IS the security policy (approval mode, YOLO, the
    /// always-allow list). A terminal-side write must be gated or the
    /// file-tools deny is unpaired theater: the agent could flip the mode
    /// off and immediately bypass the gate.
    static let arcConfigPath =
        #"(?:~/\.arc/|(?:\$home|\$\{home\})/\.arc/|(?:\$arc_home|\$\{arc_home\})/)"# +
        #"config\.json\b"#

    static let projectEnvPath = #"(?:(?:/|\.{1,2}/)?(?:[^\s/"'`]+/)*\.env(?:\.[^\s/"'`]+)*)"#
    static let projectConfigPath = #"(?:(?:/|\.{1,2}/)?(?:[^\s/"'`]+/)*config\.yaml)"#
    static let shellRcFiles =
        #"(?:~|\$home|\$\{home\})/\."# +
        #"(?:bashrc|zshrc|profile|bash_profile|zprofile)\b"#
    static let credentialFiles =
        #"(?:~|\$home|\$\{home\})/\."# +
        #"(?:netrc|pgpass|npmrc|pypirc)\b"#
    /// macOS: /etc, /var, /tmp, /home are symlinks to /private/* — match both.
    static let macosPrivateSystemPath = #"/private/(?:etc|var|tmp|home)/"#
    static let systemConfigPath = #"(?:/etc/|/private/(?:etc|var|tmp|home)/)"#

    static let sensitiveWriteTarget: String = {
        "(?:" + systemConfigPath + "|/dev/sd|" + sshSensitivePath + "|" +
        arcEnvPath + "|" + arcConfigPath + "|" + shellRcFiles + "|" + credentialFiles + ")"
    }()

    static let userSensitiveWriteTarget: String = {
        "(?:" + sshSensitivePath + "|" + shellRcFiles + "|" + credentialFiles + ")"
    }()

    static let projectSensitiveWriteTarget: String = {
        "(?:" + projectEnvPath + "|" + projectConfigPath + ")"
    }()

    /// Anchor for cp/mv/install: the sensitive path is a write target only
    /// when it is the LAST argument (the destination).
    static let commandTail = #"(?:\s*(?:&&|\|\||;).*)?$"#

    /// Boundary for stream-write rules: the path token must END at a shell
    /// word boundary. `#` is deliberately NOT a boundary char (`.env#backup`
    /// is a distinct file; `config.yaml.bak` is safe).
    static let writeTargetBoundary = #"(?=[\s;&|<>"']|$)"#

    // MARK: The 77 dangerous patterns

    static let patterns: [(String, String)] = {
        var p: [(String, String)] = []
        p.append((#"\brm\s+(-[^\s]*\s+)*/"#, "delete in root path"))
        p.append((#"\brm\s+-[^\s]*r"#, "recursive delete"))
        p.append((#"\brm\s+--recursive\b"#, "recursive delete (long flag)"))
        // GNU rm permutes options, so a recursive flag group may legally
        // FOLLOW the operands (`rm build/ -rf`). The operand run cannot
        // cross a separator, a quote, or a bare ` -- ` end-of-options marker.
        p.append((
            #"\brm\s+(?!--(?:\s|$))(?:(?!\s--(?:\s|$))[^\n"';|&])*\s"# +
            #"(?:-[a-z]*r[a-z]*\b|--recursive\b)"#,
            "recursive delete (flags after operands)"
        ))
        p.append((
            #"\bcmd(?:\.exe)?\s+/(?:c|k)\s+.*\b(?:del|erase|rd|rmdir)\b"#,
            "Windows cmd destructive delete"
        ))
        p.append((
            #"\b(?:powershell|pwsh)(?:\.exe)?\b(?:\s+-\S+)*\s+(?:-(?:command|c)\s+)?["']?(?:remove-item|rmdir|erase|del|rd|ri|rm)\b"#,
            "Windows PowerShell destructive delete"
        ))
        p.append((
            #"\b(?:powershell|pwsh)(?:\.exe)?\b.*\s-(?:encodedcommand|enc|e)\b"#,
            "PowerShell encoded command execution"
        ))
        p.append((
            #"\bchmod\s+(-[^\s]*\s+)*(777|666|o\+[rwx]*w|a\+[rwx]*w)\b"#,
            "world/other-writable permissions"
        ))
        p.append((
            #"\bchmod\s+--recursive\b.*(777|666|o\+[rwx]*w|a\+[rwx]*w)"#,
            "recursive world/other-writable (long flag)"
        ))
        p.append((#"\bchown\s+(-[^\s]*)?R\s+root"#, "recursive chown to root"))
        p.append((#"\bchown\s+--recur[a-z]*\b.*root"#, "recursive chown to root (long flag)"))
        p.append((#"\bmkfs\b"#, "format filesystem"))
        p.append((#"\bdd\s+.*if="#, "disk copy"))
        p.append((#">\s*/dev/sd"#, "write to block device"))
        p.append((#"\bDROP\s+(TABLE|DATABASE)\b"#, "SQL DROP"))
        // [^\n]* instead of .* so DOTALL cannot let a WHERE on the *next*
        // line satisfy the negative lookahead.
        p.append((#"\bDELETE\s+FROM\b(?![^\n]*\bWHERE\b)"#, "SQL DELETE without WHERE"))
        p.append((#"\bTRUNCATE\s+(TABLE)?\s*\w"#, "SQL TRUNCATE"))
        p.append((#">\s*["']?"# + sensitiveWriteTarget, "overwrite system file via redirection"))
        p.append((#">\s*/dev/sd"#, "write to block device"))
        p.append((
            #"\bsystemctl\s+(-[^\s]+\s+)*(stop|restart|disable|mask)\b"#,
            "stop/restart system service"
        ))
        p.append((#"\bkill\s+-9\s+-1\b"#, "kill all processes"))
        p.append((#"\bpkill\s+-9\b"#, "force kill processes"))
        p.append((
            #"\bkillall\s+(-[^\s]*\s+)*-(9|KILL|SIGKILL)\b"#,
            "force kill processes (killall -KILL)"
        ))
        p.append((
            #"\bkillall\s+(-[^\s]*\s+)*-s\s+(KILL|SIGKILL|9)\b"#,
            "force kill processes (killall -s KILL)"
        ))
        p.append((#"\bkillall\s+(-[^\s]*\s+)*-r\b"#, "kill processes by regex (killall -r)"))
        p.append((#":\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:"#, "fork bomb"))
        p.append((
            #"\b(curl|wget)\b.*\|\s*(?:[/\w]*/)?(?:ba)?sh(?:\s|$|-c)"#,
            "pipe remote content to shell"
        ))
        p.append((
            #"\b(bash|sh|zsh|ksh)\s+<\s*<?\s*\(\s*(curl|wget)\b"#,
            "execute remote script via process substitution"
        ))
        p.append((
            #"(?:\beval\b|\bsource\b|\.)\s*(?:\$\(\s*|`\s*)(?:curl|wget)\b"#,
            "execute remote content via command substitution"
        ))
        p.append((
            #"\b(base64|base32|base16)\s+(?:-[dD]|--decode)\b.*\|\s*\b(bash|sh|zsh|ksh|dash)\b"#,
            "pipe decoded content to shell (possible command obfuscation)"
        ))
        p.append((
            #"\bxxd\s+-r\b.*\|\s*\b(bash|sh|zsh|ksh|dash)\b"#,
            "pipe xxd-decoded content to shell (possible command obfuscation)"
        ))
        p.append((
            #"\becho\b[^|]*\|\s*\btr\b[^|]*\|\s*\b(bash|sh|zsh|ksh|dash)\b"#,
            "pipe tr-transformed output to shell (possible command obfuscation)"
        ))
        p.append((
            #"\bopenssl\b.*\b(?:base64|enc)\b[^|]*\s+-[dD]\b[^|]*\|\s*\b(bash|sh|zsh|ksh|dash)\b"#,
            "pipe openssl-decoded content to shell (possible command obfuscation)"
        ))
        p.append((#"\btee\b.*["']?"# + sensitiveWriteTarget, "overwrite system file via tee"))
        p.append((
            #"\btee\b.*["']?"# + projectSensitiveWriteTarget + #"["']?"# + writeTargetBoundary,
            "overwrite project env/config via tee"
        ))
        p.append((
            #">>?\s*["']?"# + projectSensitiveWriteTarget + #"["']?"# + writeTargetBoundary,
            "overwrite project env/config via redirection"
        ))
        p.append((#"\bxargs\s+.*\brm\b"#, "xargs with rm"))
        p.append((#"\bfind\b.*-exec(?:dir)?\s+(/\S*/)?rm\b"#, "find -exec/-execdir rm"))
        p.append((#"\bfind\b.*-delete\b"#, "find -delete"))
        // arc remap of the hermes gateway-lifecycle guard: protect the
        // running daemon from self-termination.
        p.append((
            #"\barc(?:-agent)?\s+(?:-{1,2}\S+(?:\s+\S+)?\s+)*(?:daemon|serve|gateway)\s+(stop|restart)\b"#,
            "stop/restart arc daemon (kills running agents)"
        ))
        p.append((
            #"\barc(?:-agent)?\s+update\b"#,
            "arc self-update (restarts daemon, kills running agents)"
        ))
        // Docker/podman daemon redirect — listed BEFORE the lifecycle rules.
        p.append((
            #"\bdocker\s+(?:-{1,2}\S+(?:[=\s]\S+)?\s+)*(?:-h|--host)[=\s]+\S+"#,
            "docker with remote daemon redirect (-H/--host)"
        ))
        p.append((
            #"\bdocker\s+(?:-{1,2}\S+(?:[=\s]\S+)?\s+)*(?:-c|--context)[=\s]+\S+"#,
            "docker with daemon redirect (--context: alternate daemon)"
        ))
        p.append((
            #"\bdocker\s+context\s+use\b"#,
            "docker context use (switches default daemon for future commands)"
        ))
        p.append((
            #"\bpodman\s+(?:-{1,2}\S+(?:[=\s]\S+)?\s+)*(?:--url|--connection|--identity)[=\s]+\S+"#,
            "podman with remote daemon redirect (--url/--connection/--identity)"
        ))
        p.append((
            #"\bpodman\s+(?:-{1,2}\S+(?:[=\s]\S+)?\s+)*(?:-r\b|--remote\b)"#,
            "podman remote mode (-r/--remote: remote daemon)"
        ))
        p.append((
            #"\b(?:docker_host|docker_context|container_host|container_connection)=\S+"#,
            "docker/podman daemon redirect via environment (DOCKER_HOST/CONTAINER_HOST)"
        ))
        p.append((
            #"\bdocker(?:-compose|\s+compose)\s+(?:-{1,2}\S+(?:[=\s]\S+)?\s+)*(restart|stop|kill|down)\b"#,
            "docker compose restart/stop/kill/down (container lifecycle)"
        ))
        p.append((
            #"\bdocker\s+(?:-{1,2}\S+(?:[=\s]\S+)?\s+)*(restart|stop|kill)\b"#,
            "docker restart/stop/kill (container lifecycle)"
        ))
        // Gateway protection: never start the daemon backgrounded outside a
        // service manager (arc remap of the hermes gateway run guard).
        p.append((
            #"\barc\s+serve\b.*(&\s*$|&\s*;|\bdisown\b|\bsetsid\b)"#,
            "start arc daemon outside service management"
        ))
        p.append((#"\bnohup\b.*\barc\s+serve\b"#, "start arc daemon backgrounded via nohup"))
        // Self-termination protection.
        p.append((
            #"\b(pkill|killall)\b.*\b(arc-agent|arc|hermes|gateway|cli\.py)\b"#,
            "kill agent/daemon process (self-termination)"
        ))
        p.append((
            #"\bkill\b.*\$\(\s*(pgrep|pidof)\b"#,
            "kill process via pgrep/pidof expansion (self-termination)"
        ))
        p.append((
            #"\bkill\b.*`\s*(pgrep|pidof)\b"#,
            "kill process via backtick pgrep/pidof expansion (self-termination)"
        ))
        p.append((
            #"\blaunchctl\s+(stop|kickstart|bootout|unload|kill|disable|remove)\b.*\b(arc|ai\.arc)\b"#,
            "stop/restart arc launchd service (kills running agents)"
        ))
        p.append((
            #"\b(cp|mv|install)\b.*\s"# + systemConfigPath,
            "copy/move file into system config path"
        ))
        p.append((
            #"\b(cp|mv|install)\b.*\s["']?"# + projectSensitiveWriteTarget + #"["']?"# + commandTail,
            "overwrite project env/config file"
        ))
        p.append((
            #"\b(cp|mv|install)\b.*\s["']?"# + sensitiveWriteTarget + #"[^\s"']*["']?"# + commandTail,
            "copy/move file into sensitive credential/SSH/shell-rc path"
        ))
        p.append((
            #"\bsed\s+-[^\s]*i.*(?:"# + userSensitiveWriteTarget + #")[^\s"']*"#,
            "in-place edit of sensitive credential/SSH/shell-rc path",
        ))
        p.append((
            #"\bsed\s+--in-place\b.*(?:"# + userSensitiveWriteTarget + #")[^\s"']*"#,
            "in-place edit of sensitive credential/SSH/shell-rc path (long flag)",
        ))
        p.append((
            #"\b(?:perl|ruby)\b.*(?:^|\s)-[^\s]*i\b.*(?:"# + userSensitiveWriteTarget + #")[^\s"']*"#,
            "in-place edit of sensitive credential/SSH/shell-rc path (perl/ruby)",
        ))
        p.append((
            #"\bsed\s+-[^\s]*i.*\s"# + systemConfigPath,
            "in-place edit of system config",
        ))
        p.append((
            #"\bsed\s+--in-place\b.*\s"# + systemConfigPath,
            "in-place edit of system config (long flag)",
        ))
        p.append((
            #"\bsed\s+-[^\s]*i.*(?:"# + arcConfigPath + #"|"# + arcEnvPath + #")"#,
            "in-place edit of arc config/env",
        ))
        p.append((
            #"\bsed\s+--in-place\b.*(?:"# + arcConfigPath + #"|"# + arcEnvPath + #")"#,
            "in-place edit of arc config/env (long flag)",
        ))
        p.append((
            #"\b(?:perl|ruby)\b.*(?:^|\s)-[^\s]*i\b.*(?:"# + arcConfigPath + #"|"# + arcEnvPath + #")"#,
            "in-place edit of arc config/env (perl/ruby)",
        ))
        p.append((#"\b(bash|sh|zsh|ksh)\s+<<"#, "shell execution via heredoc"))
        // Git destructive operations.
        p.append((
            #"\bgit\s+(?:-[^\s]+\s+\S+\s+)*reset\s+--h(?:a(?:r(?:d)?)?)?\b"#,
            "git reset --hard (destroys uncommitted changes)"
        ))
        p.append((#"\bgit\s+(?:-[^\s]+\s+\S+\s+)*push\b.*--forc[a-z]*\b"#, "git force push (rewrites remote history)"))
        p.append((#"\bgit\s+(?:-[^\s]+\s+\S+\s+)*push\b.*-f\b"#, "git force push short flag (rewrites remote history)"))
        p.append((#"\bgit\s+(?:-[^\s]+\s+\S+\s+)*clean\s+-[^\s]*f"#, "git clean with force (deletes untracked files)"))
        p.append((#"\bgit\s+(?:-[^\s]+\s+\S+\s+)*branch\s+-D\b"#, "git branch force delete"))
        p.append((
            #"\bgit\s+(?:-[^\s]+\s+\S+\s+)*branch\b[^;|&\n]*?(?:-d\b|--delete\b)[^;|&\n]*?(?:-f\b|--force\b)"#,
            "git branch force delete (long flags)"
        ))
        p.append((
            #"\bgit\s+(?:-[^\s]+\s+\S+\s+)*branch\b[^;|&\n]*?(?:-f\b|--force\b)[^;|&\n]*?(?:-d\b|--delete\b)"#,
            "git branch force delete (long flags, force-first)"
        ))
        p.append((
            #"\bchmod\s+\+x\b.*[;&|]+\s*\./"#,
            "chmod +x followed by immediate execution"
        ))
        p.append((
            #"\bsudo\b[^;|&\n]*?\s+(-s\b|--st[a-z]*\b|-a\b|--a[a-z]*\b)"#,
            "sudo with privilege flag (stdin/askpass/shell/list)"
        ))
        p.append((
            #"\bsudo\b[^;|&\n]*?\s+-[a-z]*[sa][a-z]*\b"#,
            "sudo with combined-flag privilege escalation"
        ))
        return p
    }()

    // MARK: Detection pipeline (mirror of detect_dangerous_command)

    /// Returns the hit description ("patternID") or nil. Order mirrors the
    /// reference exactly: parser limit → artifact exemption → variant loop
    /// over the 77 soft patterns → structural execution-flag findings.
    static func detect(_ command: String) -> String? {
        if ShellLexer.parserLimitExceeded(command) {
            return ShellLexer.parserLimitDescription
        }
        if ShellLexer.isVerificationArtifactCleanup(command) {
            return nil
        }
        let store = SecurityRegexStore.shared
        for variant in ShellLexer.detectionVariants(command) {
            if let hit = store.firstSoftMatch(variant.lowercased()) {
                return hit
            }
        }
        let normalized = ShellLexer.normalize(command)
        if let finding = ExecutionFlagDetector.findings(normalized).first {
            return finding.description
        }
        if detectLegacyExtras(normalized.lowercased()) != nil {
            return "process-control/network-exfil command (arc legacy tier)"
        }
        return nil
    }
}
