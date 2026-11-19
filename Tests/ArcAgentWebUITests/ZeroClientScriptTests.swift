// A17: the client is the ENGINE. There is no arc-owned client script in this
// tree, and this suite is why it stays that way.
//
// The program's shape: every client consequence arc ever wrote is a framework
// behaviour now — the document, the transport, fragment patching, scroll and
// form-state restore, the draft store, focus, the slash palette, sanitising,
// the dismiss stack, the upload transport and the clipboard. The last 60 lines
// lived in `Assets/overlay.js` and shipped as `/ui/init.js`; they are `data-open`
// layers, a native radio group and a CSS transition in the sheet.
//
// What is left to guard is the ABSENCE. A new `.js` — any `.js` — is a design
// regression, not a feature: it is a second owner of a consequence the engine
// already has, it is invisible to the framework's budget plugin (which pins the
// engine, the sheet, the shell and every island, but not a consumer's file), and
// no Swift test can exercise it. The old guard was a byte ceiling that had to be
// ratcheted down after every slice; the honest one is zero, because the ceiling
// a consumer overlay can justify is "the engine has no consequence for this",
// and that sentence has no members left.
//
// So the pins are structural, never a size: the file search must be empty, the
// manifest that embeds scripts must be empty, no source may name the parameter
// that wired a script into the document, and the served document must carry no
// arc script tag at all. The engine's own tags ARE there — the positive control
// that keeps "no script" from passing on a broken document.
import Foundation
import Testing
import WebUI

@testable import ArcWebUI

extension ArcWebUITestRoot {
	@Suite("zero client scripts", .serialized)
	struct ZeroClientScriptTests {

		/// the package root, from this file's own location (`…/Tests/<target>/<file>`).
		private static var root: URL {
			URL(fileURLWithPath: #filePath)
				.deletingLastPathComponent()   // ArcAgentWebUITests
				.deletingLastPathComponent()   // Tests
				.deletingLastPathComponent()   // package root
		}

		/// every file under `Sources/` with `extension`, recursively.
		private static func files(under directory: URL) -> [URL] {
			guard let walk = FileManager.default.enumerator(
				at: directory, includingPropertiesForKeys: nil
			) else { return [] }
			return walk.compactMap { $0 as? URL }
		}

		@Test("no .js file exists anywhere under Sources/")
		func noJavaScriptUnderSources() {
			let sources = Self.root.appendingPathComponent("Sources")
			let all = Self.files(under: sources)
			// a walk that found nothing would pass this test for the wrong reason.
			#expect(all.count > 200, "the Sources walk found \(all.count) files — is the tree where this test thinks it is?")
			let scripts = all.filter { $0.pathExtension == "js" }.map(\.lastPathComponent).sorted()
			#expect(scripts.isEmpty, """
				arc ships client script files again: \(scripts). The client is the \
				engine (`/ui/webui-engine.js` + its `-ext` asset); a second owner of a \
				consequence the engine already has is the defect this whole program \
				deleted. A capability the engine lacks arrives as a framework \
				behaviour with a versioned release, never as a file here.
				""")
		}

		@Test("the asset manifest embeds no script")
		func theManifestCarriesNoScript() throws {
			let manifest = Self.root.appendingPathComponent("Sources/ArcWebUI/Assets/webui-assets.json")
			let data = try Data(contentsOf: manifest)
			let root = try #require(
				JSONSerialization.jsonObject(with: data) as? [String: Any],
				"webui-assets.json must stay a JSON object with a `types` array"
			)
			let types = try #require(root["types"] as? [[String: Any]],
			                         "webui-assets.json lost its `types` array")
			#expect(types.isEmpty, """
				the manifest embeds \(types.count) type(s): \
				\(types.compactMap { $0["path"] as? String } ?? []). The framework's \
				embed plugin generates one declaration per entry and the server serves \
				it as /ui/<path>; with no script left there is nothing to embed, and an \
				entry that reappears is a client file coming back through the other door.
				""")
			#expect(!String(decoding: data, as: UTF8.self).contains(".js"),
			        "the manifest names a .js file even though its type list is empty")
		}

		@Test("no source names the deleted overlay plumbing")
		func noSourceNamesTheOverlayPlumbing() {
			let swiftFiles = Self.files(under: Self.root.appendingPathComponent("Sources"))
				.filter { $0.pathExtension == "swift" }
			#expect(swiftFiles.count > 200, "the Sources walk found \(swiftFiles.count) swift files")
			// the spellings that can only mean "a script wired into the page":
			// the parameter `AppShell.makeDocument` took, the shipped-asset value,
			// the generated declaration and the url the document linked.
			let retired = ["overlayURL", "Assets.overlay", "ArcOverlay", "/ui/init.js"]
			var offenders: [String] = []
			for file in swiftFiles {
				guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
				for name in retired where text.contains(name) {
					offenders.append("\(file.lastPathComponent): \(name)")
				}
			}
			#expect(offenders.isEmpty, """
				the deleted overlay's plumbing is referenced again: \(offenders.sorted()). \
				`makeDocument` takes no script url, `Assets` ships no script, and the \
				document links none.
				""")
		}

		@Test("the served document carries the engine's scripts and no arc script")
		func theServedDocumentIsTheEngines() {
			let doc = AppShell.makeDocument(sheetURL: "/ui/style.css")(
				.trusted(""), "data-scheme=\"tokyo-night\" data-theme=\"dark\""
			).markup.html
			let scriptTags = Self.scriptTags(in: doc)
			let srcTags = scriptTags.filter { $0.contains("src=") }
			#expect(!doc.contains("/ui/init.js"),
			        "the document links /ui/init.js again — A17 deleted the asset that was served there")
			#expect(srcTags.contains { $0.contains("/ui/webui-engine.js") },
			        "the document must still load the engine; found \(scriptTags)")
			#expect(srcTags.allSatisfy { $0.contains("/ui/webui-engine") },
			        "the document loads a script that is not the engine: \(srcTags)")
			#expect(scriptTags.count - srcTags.count <= 1,
			        "at most one inline script remains (the framework's pre-paint theme prelude); found \(scriptTags.count - srcTags.count): \(scriptTags)")
			// the sheet is still linked and still ordered after the framework's
			// base sheet (the two-sheet contract `makeDocument` owns).
			#expect(doc.contains("href=\"/ui/style.css\""), "arc's sheet must still be linked")
		}

		/// every `<script …>` open tag in a document.
		private static func scriptTags(in html: String) -> [String] {
			var tags: [String] = []
			var rest = Substring(html)
			while let start = rest.range(of: "<script") {
				guard let end = rest[start.lowerBound...].firstIndex(of: ">") else { break }
				tags.append(String(rest[start.lowerBound...end]))
				rest = rest[rest.index(after: end)...]
			}
			return tags
		}
	}
}
