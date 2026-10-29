import Foundation
import Testing
@testable import ArcAgentCore

// MARK: - Helpers

/// What a `ps` row looks like on Darwin (verified against `/bin/ps`):
/// right-aligned fixed ids, single-letter state + modifier, decimal
/// percents, 16-char-truncated `comm`, 24-char `lstart`, rest = command.
let psRow = "  1     0 Ss     0.0  0.0 /sbin/launchd    Mon Sep 28 17:51:59 2026     /sbin/launchd"
let psRowArgs = " 532     1 Ss     0.1  0.1 /usr/libexec/log Mon Oct  5 08:43:17 2026     /usr/libexec/logd"

func info(
    pid: Int32, ppid: Int32 = 1, state: String = "S", cpu: Double = 1.0, mem: Double = 0.5,
    comm: String = "proc", command: String = "/sbin/proc", startKey: String = "Mon Oct  5 08:43:17 2026"
) -> ProcessRecord {
    ProcessRecord(pid: pid, ppid: ppid, state: state, cpuPercent: cpu, memPercent: mem,
                comm: comm, command: command, startKey: startKey)
}

/// Collects HookBus emissions for a set of events.
actor HookSpy {
    var entries: [(event: String, context: HookContext)] = []
    var handler: HookHandler { { [weak self] event, context in
        await self?.record(event, context)
    } }
    func record(_ event: String, _ context: HookContext) {
        entries.append((event, context))
    }
    func all() -> [(String, HookContext)] { entries }
    func clear() { entries = [] }
}

// MARK: - Plan B: collector parsing

extension ArcCoreTestRoot {
    @Suite("Process watch — collector", .serialized)
    struct ProcessWatchCollectorTests {

        @Test("parses a Darwin ps row into a ProcessRecord")
        func parsesRow() throws {
            let p = try #require(ProcessWatchCollector.parse(line: psRow))
            #expect(p.pid == 1)
            #expect(p.ppid == 0)
            #expect(p.state == "Ss")
            #expect(p.cpuPercent == 0.0)
            #expect(p.memPercent == 0.0)
            #expect(p.comm == "/sbin/launchd")
            #expect(p.startKey == "Mon Sep 28 17:51:59 2026")
            #expect(p.command == "/sbin/launchd")
        }

        @Test("parses a row with command-line arguments")
        func parsesArguments() throws {
            let p = try #require(ProcessWatchCollector.parse(line: psRowArgs))
            #expect(p.pid == 532)
            #expect(p.comm == "/usr/libexec/log") // 16-char truncated
            #expect(p.processName == "logd")      // derived from full command
            #expect(p.command == "/usr/libexec/logd")
        }

        @Test("collects a live ps snapshot (ARC_LIVE_PS=1)")
        func liveCollect() async throws {
            guard ProcessInfo.processInfo.environment["ARC_LIVE_PS"] == "1" else { return }
            let rows = try await ProcessWatchCollector.collect()
            #expect(rows.count > 5)
            #expect(rows.contains { $0.pid == 1 })
            #expect(rows.allSatisfy { Int32($0.pid) > 0 })
        }

        @Test("skips malformed rows instead of crashing")
        func skipsMalformed() {
            #expect(ProcessWatchCollector.parse(line: "garbage") == nil)
            #expect(ProcessWatchCollector.parse(line: "") == nil)
            #expect(ProcessWatchCollector.parse(line: "  1     0 Ss     x") == nil) // non-numeric cpu
        }
    }
}

// MARK: - Plan B: scoping engine

extension ArcCoreTestRoot {
    @Suite("Process watch — scoping", .serialized)
    struct ProcessMatcherTests {

        @Test("name matches truncated comm or executable basename")
        func nameMatching() {
            let p = info(pid: 532, comm: "/usr/libexec/log", command: "/usr/libexec/logd")
            #expect(ProcessMatcher.matches(p, ProcessTarget(name: "/usr/libexec/log")))
            #expect(ProcessMatcher.matches(p, ProcessTarget(name: "logd")))
            #expect(!ProcessMatcher.matches(p, ProcessTarget(name: "log"))) // basename is logd
            #expect(!ProcessMatcher.matches(p, ProcessTarget(name: "other")))
        }

        @Test("path prefix and cmdline regex")
        func pathAndCmdline() {
            let p = info(pid: 9, command: "/usr/local/bin/arc-agent serve --port 8890")
            #expect(ProcessMatcher.matches(p, ProcessTarget(pathPrefix: "/usr/local/bin")))
            #expect(!ProcessMatcher.matches(p, ProcessTarget(pathPrefix: "/opt")))
            #expect(ProcessMatcher.matches(p, ProcessTarget(cmdline: #"arc-agent\s+serve"#)))
            #expect(!ProcessMatcher.matches(p, ProcessTarget(cmdline: #"arc-agent\s+chat"#)))
        }

        @Test("all specified fields must match (AND); empty target matches nothing")
        func andSemantics() {
            let p = info(pid: 9, command: "/usr/local/bin/arc serve")
            #expect(ProcessMatcher.matches(p, ProcessTarget(name: "arc", pathPrefix: "/usr/local/bin")))
            #expect(!ProcessMatcher.matches(p, ProcessTarget(name: "arc", pathPrefix: "/opt")))
            #expect(!ProcessMatcher.matches(p, ProcessTarget()))
        }

        @Test("invalid regex is a no-match, never a crash")
        func invalidRegex() {
            let p = info(pid: 5)
            #expect(!ProcessMatcher.matches(p, ProcessTarget(cmdline: "[")))
        }

        @Test("deny beats allowlist; built-in deny protects system processes")
        func denyWins() {
            let config = ProcessWatchConfig(
                enabled: true,
                targets: [ProcessTarget(name: "arc-daemon", control: true)],
                deny: [ProcessTarget(name: "arc-daemon")]
            )
            guard case .denied = ProcessMatcher.scope(info(pid: 10, comm: "arc-daemon"), config: config) else {
                Issue.record("configured deny did not win over a matching target")
                return
            }
            guard case .denied = ProcessMatcher.scope(info(pid: 1, comm: "launchd", command: "/sbin/launchd"), config: config) else {
                Issue.record("built-in deny (launchd/pid 1) did not win")
                return
            }
        }

        @Test("fail-closed: no targets configured == nothing allowlisted")
        func failClosed() {
            let config = ProcessWatchConfig(enabled: true) // empty targets
            let p = info(pid: 99, comm: "some-daemon")
            guard case .unlisted = ProcessMatcher.scope(p, config: config) else {
                Issue.record("process with no matching target must be unlisted")
                return
            }
        }

        @Test("control flag rides through the scope result")
        func controlFlag() {
            let config = ProcessWatchConfig(
                enabled: true,
                targets: [ProcessTarget(name: "worker", control: true)]
            )
            guard case .allowlisted(let control) = ProcessMatcher.scope(
                info(pid: 20, comm: "worker"), config: config
            ) else {
                Issue.record("expected allowlisted")
                return
            }
            #expect(control == true)
        }

        @Test("agent-owned pids are hard-denied from observation")
        func agentOwnDenied() {
            let config = ProcessWatchConfig(enabled: true, targets: [ProcessTarget(name: "worker", control: true)])
            guard case .denied = ProcessMatcher.scope(
                info(pid: 20, comm: "worker"), config: config, agentPIDs: [20]
            ) else {
                Issue.record("agent-owned process must never be 'watched'")
                return
            }
        }
    }
}

// MARK: - Plan B: config decode

extension ArcCoreTestRoot {
    @Suite("Process watch — config", .serialized)
    struct ProcessWatchConfigTests {

        @Test("decodes the process_watch block with defaults for absent keys")
        func decodesBlock() throws {
            let json = #"""
            {"enabled": true, "interval_seconds": 2.5,
             "targets": [{"name": "pytest", "control": true, "max_cpu_pct": 90, "path_prefix": "/opt"}],
             "deny": [{"cmdline": "drop"}]}
            """#
            let config = try JSONDecoder().decode(ProcessWatchConfig.self, from: Data(json.utf8))
            #expect(config.enabled == true)
            #expect(config.intervalSeconds == 2.5)
            #expect(config.maxEvents == 200) // default
            #expect(config.targets.count == 1)
            #expect(config.targets[0].name == "pytest")
            #expect(config.targets[0].control == true)
            #expect(config.targets[0].maxCpuPct == 90)
            #expect(config.targets[0].pathPrefix == "/opt")
            #expect(config.deny[0].cmdline == "drop")
        }

        @Test("round-trips through JSON")
        func roundTrip() throws {
            let config = ProcessWatchConfig(
                enabled: true, intervalSeconds: 3,
                targets: [ProcessTarget(name: "spot", cmdline: "spot", control: true)],
                deny: [ProcessTarget(name: "nope")], maxEvents: 50
            )
            let data = try JSONEncoder().encode(config)
            let back = try JSONDecoder().decode(ProcessWatchConfig.self, from: data)
            #expect(back == config)
        }
    }
}

// MARK: - Plan B: diff engine (deterministic, injected snapshots)

extension ArcCoreTestRoot {
    @Suite("Process watch — diff", .serialized)
    struct ProcessWatchDiffTests {

        private func makeService() -> ProcessWatchService {
            ProcessWatchService(config: ProcessWatchConfig(
                enabled: true,
                targets: [
                    ProcessTarget(name: "worker", maxCpuPct: 95, control: true),
                    ProcessTarget(name: "bat", control: false),
                ]
            ))
        }

        @Test("new pid emits started; gone pid emits exited")
        func startedAndExited() async {
            let service = makeService()
            let a = info(pid: 10, comm: "worker", command: "/usr/local/bin/worker",
                         startKey: "Mon Oct  5 08:00:00 2026")
            let b = info(pid: 11, comm: "bat", command: "/usr/local/bin/bat",
                         startKey: "Mon Oct  5 08:00:01 2026")
            await service.pollOnce(with: [a, b])
            #expect((await service.recentEvents()).map(\.kind) == [.started, .started])

            await service.pollOnce(with: [b])
            let events = await service.recentEvents()
            #expect(events.last == ProcessWatchEvent(
                kind: .exited, pid: 10, name: "worker", command: "/usr/local/bin/worker",
                cpuPercent: 1.0, memPercent: 0.5, at: events.last!.at
            ))
        }

        @Test("pid reuse is reported as exited(old) + started(new)")
        func pidReuse() async {
            let service = makeService()
            let old = info(pid: 10, comm: "worker", startKey: "Mon Oct  5 08:00:00 2026")
            await service.pollOnce(with: [old])
            await service.pollOnce(with: [])
            let mid = await service.recentEvents()
            #expect(mid.last?.kind == .exited)

            let reused = info(pid: 10, comm: "worker", startKey: "Tue Oct  6 09:00:00 2026")
            await service.pollOnce(with: [reused])
            let events = await service.recentEvents()
            #expect(events.count == 3)
            #expect(events[1].kind == .exited)
            #expect(events[2].kind == .started)
        }

        @Test("unlisted processes produce no events (fail-closed)")
        func unlistedSilent() async {
            let service = makeService()
            await service.pollOnce(with: [info(pid: 20, comm: "unknown-other")])
            #expect((await service.recentEvents()).isEmpty)
        }

        @Test("threshold fires once per crossing (hysteresis)")
        func thresholdEdge() async {
            let service = makeService()
            let hot = info(pid: 30, cpu: 99.0, comm: "worker")
            await service.pollOnce(with: [hot])
            var events = await service.recentEvents()
            #expect(events.last?.kind == .started) // first sighting is a start

            // Second poll at/above the cap crosses the threshold edge.
            await service.pollOnce(with: [info(pid: 30, cpu: 98.0, comm: "worker")])
            events = await service.recentEvents()
            #expect(events.last?.kind == .threshold)

            // Still above: no re-emit.
            let count = events.count
            await service.pollOnce(with: [info(pid: 30, cpu: 97.0, comm: "worker")])
            #expect((await service.recentEvents()).count == count)

            // Drops well below (hysteresis 10%), then crosses again: one re-emit.
            await service.pollOnce(with: [info(pid: 30, cpu: 50.0, comm: "worker")])
            await service.pollOnce(with: [info(pid: 30, cpu: 99.0, comm: "worker")])
            events = await service.recentEvents()
            #expect(events.last?.kind == .threshold)
            #expect(events.count == 3)
        }

        @Test("emits through HookBus with redacted command")
        func hookEmits() async throws {
            let spy = HookSpy()
            await HookBus.shared.register(
                events: ["process:started", "process:exited", "process:threshold"],
                handler: spy.handler
            )
            let service = makeService()
            let secret = "run --password hunter2 --api-key=sk-abcdefghijklmnop"
            await service.pollOnce(with: [info(pid: 40, comm: "worker", command: secret)])
            try await Task.sleep(for: .milliseconds(400))
            let entries = await spy.all()
            let started = entries.first { $0.0 == "process:started" && $0.1.int("pid") == 40 }
            let context = try #require(started?.1)
            #expect(context.int("pid") == 40)
            #expect(context.string("name") == "run")
            let redacted = try #require(context.string("command"))
            #expect(!redacted.contains("hunter2"))
            #expect(!redacted.contains("sk-abcdefghijklmnop"))
            #expect(redacted.contains("<redacted>"))
            await spy.clear()
        }
    }
}

// MARK: - Plan B: redaction

extension ArcCoreTestRoot {
    @Suite("Process watch — redaction", .serialized)
    struct ProcessRedactionTests {

        @Test("redacts common secret shapes")
        func redacts() {
            let out = ProcessRedaction.redact(
                "curl -H 'Authorization: Bearer abc123' 'https://x?a=b' --password hunter2 sk-abcdefghijklmnop"
            )
            #expect(!out.contains("abc123"))
            #expect(!out.contains("hunter2"))
            #expect(!out.contains("sk-abcdefghijklmnop"))
            #expect(out.contains("<redacted>"))
        }

        @Test("leaves ordinary commands alone")
        func leavesAlone() {
            #expect(ProcessRedaction.redact("swift test --filter ProcessWatch") == "swift test --filter ProcessWatch")
        }
    }
}

// MARK: - Plan B: control gating (no real signals are sent)

extension ArcCoreTestRoot {
    @Suite("Process watch — control", .serialized)
    struct ProcessWatchControlTests {

        @Test("invalid signal names are rejected before anything runs")
        func invalidSignal() async {
            let service = ProcessWatchService()
            await service.configure(ProcessWatchConfig(enabled: true, targets: [ProcessTarget(name: "x", control: true)]))
            await expectThrows(ProcessWatchError.invalidSignal("PIPE")) {
                _ = try await service.signal(pid: 1, signalName: "PIPE")
            }
        }

        @Test("out-of-scope pid refused (fail-closed)")
        func outOfScope() async {
            let service = ProcessWatchService()
            await service.configure(ProcessWatchConfig(enabled: true, targets: [ProcessTarget(name: "x", control: true)]))
            await expectThrows(ProcessWatchError.signalFailed(999999, "no such process")) {
                _ = try await service.signal(pid: 999999, signalName: "TERM")
            }
        }

        @Test("control: false refuses signal")
        func noControl() async throws {
            let service = ProcessWatchService(
                config: ProcessWatchConfig(enabled: true, targets: [ProcessTarget(name: "sleep", control: false)])
            )
            let slow = Process()
            slow.executableURL = URL(fileURLWithPath: "/bin/sleep")
            slow.arguments = ["30"]
            try slow.run()
            defer { slow.terminate() }
            let pid = Int32(slow.processIdentifier)
            await expectThrows(ProcessWatchError.controlNotPermitted("sleep")) {
                _ = try await service.signal(pid: pid, signalName: "TERM")
            }
            slow.terminate()
        }

        private func expectThrows(_ expected: Error, _ body: () async throws -> Void) async {
            do {
                try await body()
                Issue.record("expected \(expected) to be thrown")
            } catch let actual as ProcessWatchError {
                if String(describing: actual) != String(describing: expected) {
                    Issue.record("expected \(expected), got \(actual)")
                }
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }
    }
}

// MARK: - Plan A: owned-process events + danger classification + tool gate

extension ArcCoreTestRoot {
    @Suite("Process watch — plan A wiring", .serialized)
    struct ProcessWatchPlanATests {

        @Test("registry spawn/exit emits process:spawned and process:exited")
        func registryEvents() async throws {
            let spy = HookSpy()
            await HookBus.shared.register(events: ["process:spawned", "process:exited"], handler: spy.handler)
            let reg = ProcessRegistry.shared
            let id = try await reg.start(command: "echo plan-a; sleep 0.2")
            _ = await reg.wait(id: id, timeout: 15)
            try await Task.sleep(for: .milliseconds(400))
            let entries = await spy.all()
            let spawned = entries.contains { entry in
                entry.0 == "process:spawned" && entry.1.string("session_id") == id
            }
            #expect(spawned)
            let exited = entries.contains { entry in
                entry.0 == "process:exited" && entry.1.string("session_id") == id && entry.1.int("exit_code") == 0
            }
            #expect(exited)
            await spy.clear()
        }

        @Test("kill/pkill/killall classify dangerous")
        func killPatterns() async {
                    #expect(await detectDangerLevel("kill 1234") == .dangerous)
            #expect(await detectDangerLevel("pkill -9 -f arc serve") == .dangerous)
            #expect(await detectDangerLevel("killall dockerd") == .dangerous)
            #expect(await detectDangerLevel("echo killing the bug quickly") == .safe)
        }

        @Test("process kill and process_watch signal route through approval")
        func toolGate() {
            #expect(ArcAgent.requiresApprovalForTool(
                named: "process", arguments: #"{"action":"kill","session_id":"x"}"#
            ))
            #expect(ArcAgent.requiresApprovalForTool(
                named: "process_watch", arguments: #"{"action":"signal","pid":5,"signal":"TERM"}"#
            ))
            #expect(!ArcAgent.requiresApprovalForTool(
                named: "process_watch", arguments: #"{"action":"list"}"#
            ))
            #expect(!ArcAgent.requiresApprovalForTool(named: "terminal", arguments: #"{"command":"true"}"#) == false)
        }

        @Test("actionIs tolerates JSON whitespace")
        func actionParser() {
            #expect(ArcAgent.actionIs("signal", in: #"{"action": "signal"}"#))
            #expect(ArcAgent.actionIs("kill", in: #"{"action":"kill","pid":1}"#))
            #expect(!ArcAgent.actionIs("signal", in: #"{"action":"list"}"#))
            #expect(!ArcAgent.actionIs("signal", in: "{}"))
        }

        @Test("process_watch tool is registered")
        func registered() throws {
            let registry = try ArcAgentCore.testRegistry()
            #expect(registry.lookup(name: "process_watch") != nil)
        }

        @Test("process_watch handler smoke: targets/status/bad action")
        func toolSmoke() async throws {
            let targets = try await ProcessWatchTool.handle(["action": "targets"])
            #expect(targets.contains("no targets"))
            let status = try await ProcessWatchTool.handle(["action": "status"])
            #expect(status.contains("\"enabled\""))
            let bad = try await ProcessWatchTool.handle(["action": "bogus"])
            #expect(bad.contains("Unknown process_watch action"))
        }
    }
}
