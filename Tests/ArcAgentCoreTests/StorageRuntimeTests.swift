import Foundation
import Testing

import ArcAgentCore

/// The process storage decision. The file fallback paths are pure and must
/// never touch the network — the daemon relies on that for `--tessera-off`
/// and for an unconfigured install.
@Suite("Storage runtime")
struct StorageRuntimeTests {

    @Test("no tessera config → file storage")
    func fileWhenUnconfigured() async {
        let runtime = await StorageRuntime.resolve(tessera: nil, tesseraOff: false)
        #expect(runtime.backend == "file")
    }

    @Test("tessera-off short-circuits the probe (no connection attempt)")
    func tesseraOffSkipsProbe() async {
        let config = TesseraConfig(
            serverIP: "10.255.255.1",
            serverPort: 1,
            serverPublicKey: "",
            myPrivateKey: "",
            application: 1
        )
        let runtime = await StorageRuntime.resolve(tessera: config, tesseraOff: true)
        #expect(runtime.backend == "file")
    }
}