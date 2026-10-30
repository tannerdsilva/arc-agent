import Foundation
import Testing

/// one string literal found in a swift source file.
struct ScannedLiteral: Sendable {
	let file: String
	let line: Int

	/// the literal's interior exactly as written — interpolation code included —
	/// with backslashes removed. this is the allowlist's identity for a literal:
	/// an allowlisted string that gets reworded no longer matches, so it has to
	/// be re-approved rather than silently keeping its exemption.
	let canonical: String

	/// the interior spans that are literal text. an interpolation is code, so a
	/// tag written inside `\( … )` is found on its own literal, never on the
	/// enclosing one.
	let chunks: [String]
}

/// a lexer, not a regex.
///
/// a line-prefix `//` check calls a `///` doc comment "code", a regex cannot
/// tell `"a // b"` from a comment, and `"""` / `#"…"#` delimiters are as long as
/// the literal says they are. so this walks characters and keeps a mode stack:
/// code → interpolation → code → string, exactly the nesting swift has.
enum SwiftSourceScanner {

	private enum Kind { case code, interpolation, string }

	private struct Mode {
		var kind: Kind
		var paren = 0
		var hashes = 0
		var multiline = false
		var start = 0
		var buffer = ""
		var chunks: [String] = []

		init(kind: Kind) { self.kind = kind }
	}

	static func literals(in text: String, file: String) -> [ScannedLiteral] {
		let c = Array(text)
		let n = c.count
		let newlines = c.indices.filter { c[$0] == "\n" }
		var i = 0
		var stack: [Mode] = [Mode(kind: .code)]
		var out: [ScannedLiteral] = []

		func lineNumber(at offset: Int) -> Int {
			// newline offsets once, then a binary search per literal: a scan of
			// `Views.swift` is thousands of literals against a 5,600-line file.
			var low = 0
			var high = newlines.count
			while low < high {
				let mid = (low + high) / 2
				if newlines[mid] < offset { low = mid + 1 } else { high = mid }
			}
			return low + 1
		}

		/// everything typed into the current string since the last interpolation
		/// is one chunk of literal text.
		func flushChunk() {
			let top = stack.count - 1
			guard stack[top].kind == .string, !stack[top].buffer.isEmpty else { return }
			stack[top].chunks.append(stack[top].buffer)
			stack[top].buffer = ""
		}

		func closeString(at end: Int) {
			flushChunk()
			let mode = stack.removeLast()
			out.append(
				ScannedLiteral(
					file: file,
					line: lineNumber(at: mode.start),
					canonical: String(c[mode.start..<end]).replacingOccurrences(of: "\\", with: ""),
					chunks: mode.chunks
				)
			)
		}

		/// the closing delimiter at `at` — `"` (+ hashes) or `"""` (+ hashes).
		func delimiterEnd(at: Int, mode: Mode) -> Int? {
			let quoteRun = mode.multiline ? 3 : 1
			guard at + quoteRun <= n else { return nil }
			for k in 0..<quoteRun where c[at + k] != "\"" { return nil }
			var end = at + quoteRun
			for _ in 0..<mode.hashes {
				guard end < n, c[end] == "#" else { return nil }
				end += 1
			}
			return end
		}

		while i < n {
			let ch = c[i]

			if stack[stack.count - 1].kind != .string {
				// a line comment runs to the newline, wherever it starts.
				if ch == "/", i + 1 < n, c[i + 1] == "/" {
					while i < n, c[i] != "\n" { i += 1 }
					continue
				}
				// a block comment nests in swift, so it is counted, not scanned.
				if ch == "/", i + 1 < n, c[i + 1] == "*" {
					var depth = 0
					while i < n {
						if c[i] == "/", i + 1 < n, c[i + 1] == "*" {
							depth += 1
							i += 2
							continue
						}
						if c[i] == "*", i + 1 < n, c[i + 1] == "/" {
							depth -= 1
							i += 2
							if depth == 0 { break }
							continue
						}
						i += 1
					}
					continue
				}
				// string start: `"`, `"""`, `#…"`, `#…"""`.
				if ch == "\"" || ch == "#" {
					var hashes = 0
					if ch == "#" {
						while i + hashes < n, c[i + hashes] == "#" { hashes += 1 }
					}
					let quote = i + hashes
					if quote < n, c[quote] == "\"" {
						let multiline = quote + 2 < n && c[quote + 1] == "\"" && c[quote + 2] == "\""
						let open = multiline ? 3 : 1
						var mode = Mode(kind: .string)
						mode.hashes = hashes
						mode.multiline = multiline
						mode.start = quote + open
						stack.append(mode)
						i = quote + open
						continue
					}
					// `#if`, `#expect`, `#'#` — not a quote, not a literal.
					i += 1
					continue
				}
				if stack[stack.count - 1].kind == .interpolation {
					if ch == "(" { stack[stack.count - 1].paren += 1 }
					if ch == ")" {
						stack[stack.count - 1].paren -= 1
						if stack[stack.count - 1].paren == 0 { stack.removeLast() }
					}
				}
				i += 1
				continue
			}

			// inside a string literal
			let mode = stack[stack.count - 1]
			if ch == "\"", let end = delimiterEnd(at: i, mode: mode) {
				closeString(at: i)
				i = end
				continue
			}
			if ch == "\\" {
				var hashRun = 0
				while i + 1 + hashRun < n, c[i + 1 + hashRun] == "#" { hashRun += 1 }
				let paren = i + 1 + hashRun
				if hashRun == mode.hashes, paren < n, c[paren] == "(" {
					flushChunk()
					stack.append(Mode(kind: .interpolation))
					stack[stack.count - 1].paren = 1
					i = paren + 1
					continue
				}
				if mode.hashes == 0, i + 1 < n {
					// an escaped character: `\"` must not end the literal.
					stack[stack.count - 1].buffer.append("\\")
					stack[stack.count - 1].buffer.append(c[i + 1])
					i += 2
					continue
				}
			}
			stack[stack.count - 1].buffer.append(ch)
			i += 1
		}
		return out
	}
}

/// file → the exact literal interiors that may carry markup.
///
/// only two kinds of entry belong here:
///
/// - **bucket C, a plugin seam.** the conformers are third-party, so the ABI is
///   a string by design (see `SidebarTab.panelHTML()`).
/// - **bucket D, sanitized content.** markdown is rendered to a string by the
///   shared arc-parity renderer and enters a view through
///   `TrustedMarkup(…, from: .markdown)`; the `Raw`-equivalent call site is the
///   documentation.
///
/// chrome is neither. a `<div>` added to a builder must fail this test.
enum MarkupAllowlist {

	//: bucket c — the sidecar ABI's own fallback node, rendered by the host when
	//: the plugin socket is gone. the plugin speaks html over the wire.
	static let sidecarFallback = "<div class=\"empty-hint\">Sidecar plugin unavailable.</div>"

	//: bucket c — the shell's region wrappers belong to the plugin kit's
	//: contract: a tab returns a fragment and the bridge owns `#panel` / `#main`.
	static let bridgePanelWrapper = "<div id=\"panel\">(plan.inner)</div>"
	static let bridgeMainWrapper = "<div id=\"main\">(plan.inner)</div>"
	//: bucket c — `SidebarTabIconRenderer`'s emoji span: an icon ABI value that
	//: crosses the module boundary as markup.
	static let bridgeEmojiSpan = "<span class=\"rail-emoji\" role=\"img\" aria-hidden=\"true\">(SidebarTabHTML.escape(glyph))</span>"

	//: bucket c — `ArcRing` writes its two svg elements through
	//: `HTMLBuffer.beginElement` (the framework's own authoring path): `Tag` has
	//: no `svg`/`circle` case, and the dasharray is a computed style. the element
	//: names are confined to this one type by construction.
	static let ringTrack = " class=\"ctx-ring-track\" cx=\"12\" cy=\"12\" r=\"9.75\""
	static let ringValue = " class=\"ctx-ring-value\" cx=\"12\" cy=\"12\" r=\"9.75\" style=\"stroke-dasharray:(circ);stroke-dashoffset:(offset)\""

	//: bucket d — a fenced code block's chrome, emitted by `renderMarkdown`
	//: (the markdown pipeline). the whole string is content: it lands in
	//: `TrustedMarkup(…, from: .markdown)` with the rest of the transcript.
	static let codeFence =
		"<div class=\"code-wrap\"><button type=\"button\" class=\"copy-code\" data-copy=\"(esc(clean))\" title=\"Copy code\">Copy</button><pre><code(langAttr)>(esc(clean))</code></pre></div>"
	//: bucket d — the `.md` container around rendered markdown.
	static let mdBox = "<div class=\"md\">(renderMarkdown(markdown))</div>"

	static let entries: [String: Set<String>] = [
		"Sources/ArcWebUI/SidecarPlugin.swift": [sidecarFallback],
		"Sources/ArcWebUI/SidebarTabBridge.swift": [
			bridgePanelWrapper, bridgeMainWrapper, bridgeEmojiSpan,
		],
		"Sources/ArcWebUI/Components/ArcRing.swift": [ringTrack, ringValue],
		"Sources/ArcWebUI/Views.swift": [codeFence, mdBox],
	]
}

extension ArcWebUITestRoot {
	@Suite("No markup strings", .serialized)
	struct NoMarkupStringsTests {

		/// the roots the guard covers: arc's own chrome, and the sheet (which has no
		/// markup in it at all, so a hit there is a mistake).
		static let roots = ["Sources/ArcWebUI", "Sources/ArcTheme"]

		static var repoRoot: URL {
			URL(fileURLWithPath: #filePath)
				.deletingLastPathComponent()   // ArcAgentWebUITests
				.deletingLastPathComponent()   // Tests
				.deletingLastPathComponent()   // repo
		}

		/// every `.swift` file under the roots, repo-relative.
		static func sourceFiles() throws -> [URL] {
			var files: [URL] = []
			for root in roots {
				let dir = repoRoot.appendingPathComponent(root)
				let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
				while let url = walker?.nextObject() as? URL {
					if url.pathExtension == "swift" { files.append(url) }
				}
			}
			return files.sorted { $0.path < $1.path }
		}

		static func repoRelative(_ url: URL) -> String {
			let base = repoRoot.standardizedFileURL.path + "/"
			let path = url.standardizedFileURL.path
			return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
		}

		static func scanned() throws -> [ScannedLiteral] {
			var literals: [ScannedLiteral] = []
			for url in try sourceFiles() {
				let text = try String(contentsOf: url, encoding: .utf8)
				literals += SwiftSourceScanner.literals(in: text, file: repoRelative(url))
			}
			return literals
		}

		/// the element names that make `<word` markup.
		///
		/// a placeholder is prose: the help legend writes `<name>`, the clarify prompt
		/// delimits its question with `<question>`, a validation message quotes
		/// `-y <server>`. none is a tag, and allowlisting a 900-character prompt
		/// literal to say so would make the allowlist unmaintainable — so the matcher
		/// asks whether the word names an html element at all.
		static let elementNames: Set<String> = [
			"a", "abbr", "article", "aside", "audio", "b", "blockquote", "body", "br",
			"button", "canvas", "caption", "circle", "code", "col", "colgroup", "dd",
			"del", "details", "dfn", "dialog", "div", "dl", "dt", "em", "fieldset",
			"figcaption", "figure", "footer", "form", "g", "h1", "h2", "h3", "h4", "h5",
			"h6", "head", "header", "hr", "html", "i", "iframe", "img", "input", "ins",
			"kbd", "label", "legend", "li", "line", "link", "main", "mark", "math",
			"meta", "meter", "nav", "ol", "optgroup", "option", "output", "p", "path",
			"picture", "pre", "progress", "q", "s", "samp", "script", "section",
			"select", "small", "source", "span", "strong", "style", "sub", "summary",
			"sup", "svg", "table", "tbody", "td", "template", "textarea", "tfoot",
			"th", "thead", "time", "tr", "track", "u", "ul", "var", "video",
		]

		/// a `/* … */` span inside a literal is prose as well: `ChromeSheet` is css in
		/// a string, and its rules are documented in css comments.
		static func stripBlockComments(_ text: String) -> String {
			var out = ""
			var rest = Substring(text)
			while let open = rest.range(of: "/*") {
				out += rest[..<open.lowerBound]
				guard let close = rest.range(of: "*/", range: open.upperBound..<rest.endIndex) else {
					rest = Substring("")
					break
				}
				rest = rest[close.upperBound...]
			}
			out += rest
			return out
		}

		/// `<element` anywhere in the literal's text.
		static func hasMarkup(_ chunk: String) -> Bool {
			let text = stripBlockComments(chunk)
			var search = Substring(text)
			while let lt = search.firstIndex(of: "<") {
				let after = search[search.index(after: lt)...]
				var name = ""
				for character in after {
					if character.isLetter || character.isNumber {
						name.append(character)
					} else {
						break
					}
				}
				if elementNames.contains(name.lowercased()) { return true }
				search = after
			}
			return false
		}

		/// `<tag` inside literal text — the tag name only, so the message names the
		/// offender without pretending to know where its attributes end.
		static func tagOffenders() throws -> [String] {
			let allowed = MarkupAllowlist.entries
			var offenders: [String] = []
			for literal in try scanned() {
				let permitted = allowed[literal.file] ?? []
				if permitted.contains(literal.canonical) { continue }
				guard literal.chunks.contains(where: hasMarkup) else { continue }
				offenders.append("\(literal.file):\(literal.line) — \(literal.canonical.prefix(160))")
			}
			return offenders
		}

		@Test("arc's own sources carry no html tags in string literals")
		func sourcesCarryNoMarkup() throws {
			let literals = try Self.scanned()
			// a floor, so a scanner that finds nothing fails instead of passing:
			// this tree has thousands of literals, and "0 offenders" is only news
			// if the scanner read them.
			#expect(
				literals.count > 500,
				"the scanner found \(literals.count) string literals — it is broken, not the code"
			)

			let offenders = try Self.tagOffenders()
			#expect(
				offenders.isEmpty,
				"""
				\(offenders.count) string literal(s) carry html tags:
				\(offenders.joined(separator: "\n"))
				"""
			)
		}

		@Test("no string literal carries a style attribute")
		func sourcesCarryNoInlineStyleAttribute() throws {
			let literals = try Self.scanned()
			#expect(literals.count > 500, "the scanner found \(literals.count) literals — it is broken")

			var offenders: [String] = []
			for literal in literals {
				let permitted = MarkupAllowlist.entries[literal.file] ?? []
				if permitted.contains(literal.canonical) { continue }
				for chunk in literal.chunks {
					// `style="` — and its escaped spelling inside a swift literal.
					let pattern = #"style=\\?""#
					guard chunk.range(of: pattern, options: .regularExpression) != nil else { continue }
					offenders.append("\(literal.file):\(literal.line) — \(literal.canonical.prefix(160))")
					break
				}
			}
			#expect(
				offenders.isEmpty,
				"""
				\(offenders.count) literal(s) carry an inline style attribute; \
				use `.style(property, value)` or a sheet class:
				\(offenders.joined(separator: "\n"))
				"""
			)
		}

		/// the allowlist must not rot: a renamed file leaves a dead exemption, and a
		/// dead exemption is how a guard quietly widens.
		@Test("every allowlisted file exists")
		func allowlistFilesExist() {
			for file in MarkupAllowlist.entries.keys {
				#expect(
					FileManager.default.fileExists(atPath: Self.repoRoot.appendingPathComponent(file).path),
					"\(file) is allowlisted but does not exist"
				)
			}
		}

		/// the scanner's own fixture. every case below is a shape this tree really
		/// contains, and each one is a way a naive scanner goes wrong: a doc comment
		/// that reads like code, a block comment spanning lines, an escaped quote, a
		/// raw string, a raw multi-line string, and an interpolation whose *own*
		/// literal carries the tag.
		@Test("the scanner strips comments and reads raw strings")
		func scannerSelfCheck() {
			let sample = ##"""
			// a line comment with <div class="no">
			/// a doc comment with <span> in it
			/* a block
			   comment with <table> across lines */
			let a = "plain"
			let b = "<div class=\"real\">"
			let c = #"<section> and "quoted" inside"#
			let d = """
			multi <b>line</b>
			"""
			let e = #"""
			raw <i>multi</i>
			"""#
			let f = "escaped \" quote keeps the literal open"
			let g = "\(inner("<em>"))"
			let h = "no tag here > just text"
			// a placeholder is prose, not markup: `<name>` is not an element.
			let i = "Switch workspace <name>"
			"""##

			let literals = SwiftSourceScanner.literals(in: sample, file: "sample.swift")
			// a, b, c, d, e, f, g, h, i, and the `"<em>"` inside g's interpolation.
			#expect(literals.count == 10, "found \(literals.count) literals, expected 10")
			#expect(literals.allSatisfy { !$0.file.isEmpty })

			let tagged = literals.filter { literal in
				literal.chunks.contains(where: Self.hasMarkup)
			}
			// b, c, d, e, and the inner `"<em>"` — never the comments, never `a`, and
			// not the `<name>` placeholder in `i`.
			#expect(tagged.count == 5, "tagged literals: \(tagged.map(\.canonical))")

			for literal in tagged {
				#expect(
					!literal.canonical.hasPrefix("//") && !literal.canonical.hasPrefix("/*"),
					"a comment was scanned as a literal: \(literal.canonical)"
				)
			}

			let canonicals = tagged.map(\.canonical)
			#expect(canonicals.contains("<div class=\"real\">"))
			#expect(canonicals.contains(#"<section> and "quoted" inside"#))
			#expect(canonicals.contains("<em>"))
			#expect(Self.hasMarkup("a div in prose: <div class=x>"))
			#expect(!Self.hasMarkup("a placeholder: <name>, a prompt tag: <question>"))
			#expect(!Self.hasMarkup("a css comment: /* <small> is a clamp */"))
		}
	}
}
