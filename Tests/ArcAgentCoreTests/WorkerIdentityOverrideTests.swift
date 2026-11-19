import Testing
import Foundation
@testable import ArcAgentCore

/// Worker-identity override (settings backbone): a kanban card worker is
/// spawned with `ARC_TESSERA_WORKER_PRIVATE_KEY` so it never roams the
/// daemon's relay peer. The override fires only inside a worker run
/// (`ARC_KANBAN_TASK_ID` set) — the daemon's own environment carries the same
/// value (the start script exports ~/.arc/.env wholesale) and must keep the
/// main identity. Process environment only; a dotenv value is never honored.
@Suite("Worker identity override", .serialized)
struct WorkerIdentityOverrideTests {

    private let mainKey = "bWFpbi1rZXktMzItYnl0ZXMtYmFzZTY0LWZvcm1hdA=="
    private let workerKey = "d29ya2VyLWtleS0zMi1ieXRlcy1iYXNlNjQtZm9ybWF0"

    private func tesseraConfig() -> ArcConfig {
        var config = ArcConfig()
        config.tessera = TesseraConfig(
            serverIP: "127.0.0.1", serverPort: 51820,
            serverPublicKey: "srv", myPrivateKey: mainKey, application: 1)
        return config
    }

    private func apply(
        _ config: ArcConfig,
        environment: [String: String],
        dotenv: [String: String] = [:]
    ) -> ArcConfig {
        applyEnvironmentOverrides(config, environment: environment, dotenv: dotenv)
    }

    @Test("worker run: private key replaced by the inherited worker key")
    func workerGetsWorkerKey() {
        let resolved = apply(
            tesseraConfig(),
            environment: [
                "ARC_KANBAN_TASK_ID": "t-1",
                "ARC_TESSERA_WORKER_PRIVATE_KEY": workerKey,
            ])
        #expect(resolved.tessera?.myPrivateKey == workerKey)
        #expect(resolved.tessera?.serverPublicKey == "srv")  // relay identity unchanged
    }

    @Test("daemon: the same env value is ignored without the spawn marker")
    func daemonKeepsMainKey() {
        let resolved = apply(
            tesseraConfig(),
            environment: ["ARC_TESSERA_WORKER_PRIVATE_KEY": workerKey])
        #expect(resolved.tessera?.myPrivateKey == mainKey)
    }

    @Test("worker run: dotenv value is never honored")
    func dotenvValueIgnored() {
        let resolved = apply(
            tesseraConfig(),
            environment: ["ARC_KANBAN_TASK_ID": "t-1"],
            dotenv: ["ARC_TESSERA_WORKER_PRIVATE_KEY": workerKey])
        #expect(resolved.tessera?.myPrivateKey == mainKey)
    }

    @Test("worker run: no override when no tessera backend is configured")
    func noBackendNoOverride() {
        let resolved = apply(
            ArcConfig(),
            environment: [
                "ARC_KANBAN_TASK_ID": "t-1",
                "ARC_TESSERA_WORKER_PRIVATE_KEY": workerKey,
            ])
        #expect(resolved.tessera == nil)
    }
}
