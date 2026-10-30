import Testing
import Foundation
@testable import ArcWebUI

/// a builder that returns a `View` and is interpolated into a `String` ships
/// swift's debug description — `ModifiedView<…>`, including a per-process
/// address — as page text. this bit twice during phase 5 (the main-model
/// dropdown shipped broken for three phases because of it), so it is a rule
/// with a test rather than a comment.

extension ArcWebUITestRoot {
	@Suite("render boundary contract", .serialized)
	struct RenderBoundaryContractTests {

	    private static func source(at path: String) -> String {
	        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
	    }

	    /// `name(` sites that are function *declarations*, not call sites.
	    private static func viewBuilders(in src: String) -> [String] {
	        let pattern = #"func (\w+)\([^)]*\)\s*->\s*(?:some\s+WebUI\.View|\(any\s+WebUI\.View\)\?|\[any WebUI\.View\])"#
	        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
	        let ns = src as NSString
	        return re.matches(in: src, range: NSRange(location: 0, length: ns.length)).map {
	            ns.substring(with: $0.range(at: 1))
	        }
	    }

	    @Test("no view builder is interpolated into a string")
	    func noInterpolatedViewBuilders() {
	        let src = Self.source(at: "Sources/ArcWebUI/Views.swift")
	        let builders = Self.viewBuilders(in: src)
	        #expect(!builders.isEmpty, "the scan must actually find view builders")

	        var offenders: [String] = []
	        for name in builders where src.contains("\\(\(name)())") {
	            offenders.append(name)
	        }
	        #expect(offenders.isEmpty,
	                """
	                these builders return a View but are interpolated into a String, \
	                so the page gets a debug description instead of markup: \(offenders). \
	                route them through render(…) at the call site.
	                """)
	    }

	    @Test("the scan sees a real offender")
	    func scanCatchesAnOffender() {
	        // negative control: the rule must fail on the shape it bans.
	        let fake = """
	        func someCard() -> some WebUI.View { Text("x") }
	        let html = "<div>\\(someCard())</div>"
	        """
	        let builders = Self.viewBuilders(in: fake)
	        #expect(builders == ["someCard"])
	        #expect(fake.contains("\\(\(builders[0])())"),
	                "the detector must match the interpolation it is meant to catch")
	    }
	}
}
