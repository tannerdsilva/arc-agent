import ArcSidebarTabs
import Foundation
import Testing

/// The JSON-line wire codec both processes share: every payload that
/// crosses the sidecar boundary must survive an encode/decode round trip
/// byte-for-byte in semantic value terms.
@Suite("Sidecar protocol codec")
struct SidecarProtocolTests {

    @Test("SidecarValue round-trips every kind")
    func valueRoundTrip() throws {
        let value: SidecarValue = .obj([
            "s": .string("hello"),
            "n": .number(3.5),
            "b": .bool(true),
            "arr": .array([.string("x"), .null]),
            "nested": .obj(["k": .string("v")]),
            "nil": .null,
        ])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(SidecarValue.self, from: data)
        #expect(decoded == value)
        #expect(decoded.key("s")?.string == "hello")
        #expect(decoded.key("nested")?.key("k")?.string == "v")
    }

    @Test("envelope round-trips requests and replies")
    func envelopeRoundTrip() throws {
        let request = SidecarEnvelope.request(
            id: 7,
            method: SidecarMethod.render,
            params: .obj(["tab": .string("github"), "region": .string("main")])
        )
        let reqData = try JSONEncoder().encode(request)
        let req = try JSONDecoder().decode(SidecarEnvelope.self, from: reqData)
        #expect(req.id == 7)
        #expect(req.method == "render")
        #expect(req.params?.key("tab")?.string == "github")

        let reply = SidecarEnvelope.reply(id: 7, result: .string("<div>ok</div>"))
        let rep = try JSONDecoder().decode(SidecarEnvelope.self, from: JSONEncoder().encode(reply))
        #expect(rep.id == 7)
        #expect(rep.result?.string == "<div>ok</div>")
        #expect(rep.error == nil)

        let failure = SidecarEnvelope.reply(id: 8, error: SidecarError(code: -32603, message: "boom"))
        let fail = try JSONDecoder().decode(SidecarEnvelope.self, from: JSONEncoder().encode(failure))
        #expect(fail.error?.code == -32603)
        #expect(fail.error?.message == "boom")
    }

    @Test("tab descriptor round-trips all icon kinds")
    func descriptorRoundTrip() throws {
        let desc = SidecarTabDescriptor(
            id: "github",
            title: "GitHub",
            tooltip: "GitHub",
            iconKind: "custom",
            iconA: "repo",
            iconB: "<path d=\"M0 0\"/>"
        )
        let decoded = try JSONDecoder().decode(
            SidecarTabDescriptor.self,
            from: JSONEncoder().encode(desc)
        )
        #expect(decoded == desc)
        #expect(decoded.iconB == "<path d=\"M0 0\"/>")
    }

    @Test("line accumulator emits full lines only and tolerates splits")
    func lineAccumulator() async {
        let collector = LineCollector()
        let acc = SidecarLineAccumulator { line in
            Task { await collector.append(line) }
        }
        acc.feed(Data("{\"id\":1}\n".utf8))
        acc.feed(Data("{\"id\":2".utf8))
        acc.feed(Data("}\n{\"id\":3}\n\n".utf8))
        // wait for the hop
        try? await Task.sleep(for: .milliseconds(50))
        let lines = await collector.lines
        #expect(lines == ["{\"id\":1}", "{\"id\":2}", "{\"id\":3}"])
    }
}

/// Thread-safe line collector for the accumulator test.
private actor LineCollector {
    var lines: [String] = []
    func append(_ line: String) {
        lines.append(line)
    }
}
