import Testing
import WebUICore

/// The engine sends checkbox `checked` state as a JSON boolean (never a
/// string). This test pins the accessor that toggle wires use, so a future
/// rework of the frame shape cannot silently re-break every switch.
@Suite("EventData checked accessor")
struct EventDataCheckedTests {
    @Test("boolean checked value is readable")
    func readsBooleanChecked() {
        let event = EventData(
            component: "ap-skill-locks",
            event: "change",
            data: ["value": .string("ap-skill-lock-foo"), "checked": .bool(true)]
        )
        #expect(event.checked == true)
    }

    @Test("false and nil edges")
    func falseAndNilEdges() {
        let off = EventData(component: "x", event: "change", data: ["checked": .bool(false)])
        #expect(off.checked == false)

        let absent = EventData(component: "x", event: "change", data: ["value": .string("1")])
        #expect(absent.checked == nil)
    }

    @Test("string checked is not misread as boolean")
    func stringCheckedIsNil() {
        // a string-typed checked field must NOT satisfy the boolean channel
        // (it would have made every toggle read as false before this fix).
        let weird = EventData(component: "x", event: "change", data: ["checked": .string("true")])
        #expect(weird.checked == nil)
    }
}
