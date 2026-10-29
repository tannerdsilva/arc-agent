import Foundation

/// The refusal that keeps arc from creating processes it cannot stop.
///
/// arc owns the process group of everything it spawns (see ``SubprocessRunner``),
/// so one teardown signal reaches a whole tree. That guarantee has one hole the
/// spawn contract cannot close: a command that *hands its process away* — to
/// init/launchd through `setsid`/`nohup`, or into the background of a shell that
/// then exits — leaves arc's reach entirely.
///
/// The refusal is **absolute**: no override flag, no configuration, and it fires
/// identically on the foreground path and the `background=true` path, because a
/// tracked job that `nohup`s its real work outlives arc's tracking just as surely
/// as a foreground one escapes it. The supported way to run long-lived work is
/// `background=true`, which arc tracks, polls and kills — that is the alternative
/// every refusal names.
///
/// ## Honest limit
///
/// this is a static guard on the command line arc is asked to run. A detachment
/// performed *inside* a script (`./daemonize.sh`) or by a program that calls
/// `setsid(2)` itself is not visible here — the same "cooperative descendants"
/// boundary SwiftSlash documents, which only a container or cgroup can close.
public enum DetachmentPolicy {

	/// The wrappers that hand a process to init/launchd. After one of these the
	/// process is outside arc's control, which arc does not allow.
	public static let refusingWrappers: Set<String> = ["setsid", "nohup", "disown"]

	/// The shells whose `-c` argument the shell itself executes, so the scan
	/// follows the command into it.
	private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh"]

	/// The wrappers that only *forward* a command; stripped before the program
	/// name is read, so `sudo setsid x` is seen as `setsid`.
	private static let forwarders: Set<String> = ["env", "sudo", "command"]

	/// How far the scan follows `sh -c '…'` and command substitutions.
	private static let maxDepth = 4

	/// Returns the refusal text when `command` would detach a process, or `nil`
	/// when the command is allowed.
	public static func refusal(for command: String) -> String? {
		guard let offense = scan(command, depth: 0) else { return nil }
		return message(for: offense)
	}

	// MARK: - the offense

	private enum Offense {
		/// a wrapper that hands the process away by name.
		case wrapper(String)
		/// a bare `&`: the shell backgrounds the process and arc's teardown
		/// cannot reach it once the shell that owns it exits.
		case backgrounding
	}

	private static func message(for offense: Offense) -> String {
		let reason: String
		switch offense {
		case .wrapper(let name):
			reason = "'\(name)' hands the process to init/launchd"
		case .backgrounding:
			reason = "a trailing '&' backgrounds the process outside arc's tree"
		}
		return "Refused: \(reason), and arc does not create processes it cannot stop. "
			+ "Use background=true — arc tracks the process and the process tool manages it."
	}

	// MARK: - the scan

	private static func scan(_ command: String, depth: Int) -> Offense? {
		guard depth <= maxDepth else { return nil }

		var scanner = CommandScanner(command)
		let tokens = scanner.tokenize()

		// simple commands, split on the control operators the shell honors.
		var commands: [[String]] = [[]]
		var substitutions: [String] = []
		var sawBackgrounding = false

		for token in tokens {
			switch token {
			case .separator:
				commands.append([])
			case .backgrounding:
				sawBackgrounding = true
				commands.append([])
			case .word(let text):
				commands[commands.count - 1].append(text)
			case .substitution(let body):
				substitutions.append(body)
			}
		}

		// a bare `&` is a detachment regardless of what the commands are.
		if sawBackgrounding { return .backgrounding }

		// the shell would execute these, so the scan must too.
		for body in substitutions {
			if let offense = scan(body, depth: depth + 1) { return offense }
		}

		for words in commands {
			guard let start = programIndex(words) else { continue }
			let binary = (words[start] as NSString).lastPathComponent
			if refusingWrappers.contains(binary) { return .wrapper(binary) }
			// `sh -c 'setsid z'`: the string is a command line in its own right.
			if shells.contains(binary), let script = shellScript(words, from: start + 1),
			   let offense = scan(script, depth: depth + 1) {
				return offense
			}
		}
		return nil
	}

	/// the index of the program name: leading `VAR=value` assignments and
	/// forwarding wrappers (`env`, `sudo`, `command`) are skipped — the same
	/// prefix handling ``CheckpointGuard`` uses for its destructive-command set.
	private static func programIndex(_ words: [String]) -> Int? {
		var index = 0
		while index < words.count {
			let word = words[index]
			if isAssignment(word) { index += 1; continue }
			if forwarders.contains((word as NSString).lastPathComponent) { index += 1; continue }
			return index
		}
		return nil
	}

	private static func isAssignment(_ word: String) -> Bool {
		guard let separator = word.firstIndex(of: "="), separator != word.startIndex else { return false }
		return word[..<separator].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
	}

	/// the script a shell would run: the argument after a `-c`-style flag
	/// (`-c`, `-lc`, `-ec`), if there is one.
	private static func shellScript(_ words: [String], from start: Int) -> String? {
		var index = start
		while index < words.count {
			let word = words[index]
			if word.hasPrefix("-"), !word.hasPrefix("--"), word.dropFirst().contains("c") {
				let next = index + 1
				return next < words.count ? words[next] : nil
			}
			index += 1
		}
		return nil
	}
}

// MARK: - tokenizer

/// Splits a command line the way the shell reads it: quote-aware, with the
/// control operators (`;`, `&&`, `||`, `|`, `|&`, newline) and a bare `&` as
/// boundaries, and with command substitutions lifted out for recursion.
///
/// `&` is read by context, because it means three different things: `&&` is an
/// AND list, `&>`/`>&`/`2>&1` are redirections, `|&` is a pipe — and only a bare
/// `&` backgrounds.
private struct CommandScanner {

	enum Token {
		case word(String)
		case separator
		case backgrounding
		case substitution(String)
	}

	private let chars: [Character]
	private var index = 0

	init(_ text: String) {
		self.chars = Array(text)
	}

	private var isAtEnd: Bool { index >= chars.count }

	private func peek(_ offset: Int = 0) -> Character? {
		let position = index + offset
		return position < chars.count ? chars[position] : nil
	}

	mutating func tokenize() -> [Token] {
		var tokens: [Token] = []
		var word = ""

		func flush() {
			guard !word.isEmpty else { return }
			tokens.append(.word(word))
			word = ""
		}

		while let character = peek() {
			switch character {
			case "'":
				index += 1
				while let inner = peek(), inner != "'" {
					word.append(inner)
					index += 1
				}
				if !isAtEnd { index += 1 }
			case "\"":
				index += 1
				while let inner = peek(), inner != "\"" {
					if inner == "\\", let escaped = peek(1) {
						word.append(escaped)
						index += 2
						continue
					}
					// substitutions still run inside double quotes.
					if inner == "$", peek(1) == "(" {
						flush()
						tokens.append(.substitution(captureParenthesized()))
						continue
					}
					if inner == "`" {
						flush()
						tokens.append(.substitution(captureBacktick()))
						continue
					}
					word.append(inner)
					index += 1
				}
				if !isAtEnd { index += 1 }
			case "\\":
				index += 1
				if let escaped = peek() {
					word.append(escaped)
					index += 1
				}
			case "`":
				flush()
				tokens.append(.substitution(captureBacktick()))
			case "$":
				if peek(1) == "(" {
					flush()
					tokens.append(.substitution(captureParenthesized()))
				} else {
					word.append(character)
					index += 1
				}
			case ";", "\n":
				flush()
				tokens.append(.separator)
				index += 1
			case "|":
				flush()
				index += (peek(1) == "|" || peek(1) == "&") ? 2 : 1
				tokens.append(.separator)
			case "&":
				if peek(1) == "&" {
					flush()
					index += 2
					tokens.append(.separator)
				} else if peek(1) == ">" || word.hasSuffix(">") {
					// `&>` and `>&` (e.g. `2>&1`) are redirections, not
					// backgrounding — keep them in the word.
					word.append(character)
					index += 1
				} else {
					flush()
					tokens.append(.backgrounding)
					index += 1
				}
			case " ", "\t":
				flush()
				index += 1
			default:
				word.append(character)
				index += 1
			}
		}
		flush()
		return tokens
	}

	private mutating func captureBacktick() -> String {
		index += 1
		var body = ""
		while let inner = peek(), inner != "`" {
			body.append(inner)
			index += 1
		}
		if !isAtEnd { index += 1 }
		return body
	}

	private mutating func captureParenthesized() -> String {
		index += 2   // consume `$(`
		var body = ""
		var depth = 1
		while let inner = peek() {
			if inner == "(" { depth += 1 }
			if inner == ")" {
				depth -= 1
				if depth == 0 { break }
			}
			body.append(inner)
			index += 1
		}
		if !isAtEnd { index += 1 }
		return body
	}
}