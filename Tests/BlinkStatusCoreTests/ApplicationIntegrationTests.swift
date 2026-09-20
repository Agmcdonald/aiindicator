import XCTest
import BlinkStatusCore
@testable import blink_statusd

final class ApplicationIntegrationTests: XCTestCase {
    func testDesktopPriorityAndTermination() async {
        let output = RecordingOutput()
        let daemon = makeDaemon(output)
        await daemon.applicationChanged("com.openai.codex", open: true)
        await assertOutput(output, .openai, .ready)
        await daemon.receive(hook("com.openai.codex-cli", "one", .working))
        await assertOutput(output, .openai, .working)
        await daemon.accessibilityChanged("com.openai.codex", state: .attention)
        await assertOutput(output, .openai, .attention)
        await daemon.accessibilityChanged("com.openai.codex", state: .ready)
        await assertOutput(output, .openai, .working)
        await daemon.receive(hook("com.openai.codex-cli", "one", nil))
        await assertOutput(output, .openai, .ready)
        await daemon.applicationChanged("com.openai.codex", open: false)
        await assertOutput(output, .openai, nil)
        // A delayed Accessibility callback after termination must not resurrect presence.
        await daemon.accessibilityChanged("com.openai.codex", state: .working)
        await assertOutput(output, .openai, nil)
    }

    func testIndependentProfilesAndMultipleCLISessions() async {
        let output = RecordingOutput()
        let daemon = makeDaemon(output)
        await daemon.applicationChanged("com.anthropic.claudefordesktop", open: true)
        await assertOutput(output, .claude, .ready)
        let initialOpenAI = await output.values[.openai]
        XCTAssertNil(initialOpenAI)
        await daemon.receive(hook("com.openai.codex-cli", "same", .attention))
        await daemon.receive(hook("com.anthropic.claude-code", "same", .working))
        await daemon.receive(hook("com.anthropic.claude-code", "two", .ready))
        await daemon.applicationChanged("com.anthropic.claudefordesktop", open: false)
        await assertOutput(output, .claude, .working)
        await assertOutput(output, .openai, .attention)
        await daemon.receive(hook("com.anthropic.claude-code", "same", nil))
        await assertOutput(output, .claude, .ready)
        await daemon.receive(hook("com.anthropic.claude-code", "two", nil))
        await assertOutput(output, .claude, nil)
        await assertOutput(output, .openai, .attention)
    }

    func testUnknownIDsAndCrossApplicationClearAreIsolated() async {
        let output = RecordingOutput()
        let daemon = makeDaemon(output)
        await daemon.receive(hook("com.openai.codex-cli", "same", .working))
        await daemon.receive(hook("com.openai.codex", "same", nil))
        await assertOutput(output, .openai, .working)
        let count = await output.count
        await daemon.receive(hook("unknown", "same", .attention))
        await daemon.applicationChanged("unknown", open: true)
        await daemon.accessibilityChanged("unknown", state: .attention)
        let after = await output.count
        XCTAssertEqual(count, after)
    }

    func testExpiredHookLeaseRespectsDesktopPresence() async {
        let output = RecordingOutput()
        let clock = TestClock()
        let daemon = Daemon(renderers: output.renderers, now: { clock.now })
        await daemon.applicationChanged("com.openai.codex", open: true)
        await daemon.receive(hook("com.openai.codex-cli", "one", .working, expiry: 10))
        await daemon.receive(hook("com.anthropic.claude-code", "two", .working, expiry: 10))
        clock.now = Date(timeIntervalSince1970: 10)
        await daemon.maintain()
        await assertOutput(output, .openai, .ready)
        await assertOutput(output, .claude, nil)
    }

    func testOlderHookUpdateCannotOverwriteNewerState() async {
        let output = RecordingOutput()
        let daemon = makeDaemon(output)

        await daemon.receive(hook("com.openai.codex-cli", "one", .attention, timestamp: 20, expiry: 100))
        await daemon.receive(hook("com.openai.codex-cli", "one", .working, timestamp: 10, expiry: 100))

        await assertOutput(output, .openai, .attention)
    }

    func testOlderHookUpdateCannotResurrectAfterNewerClear() async {
        let output = RecordingOutput()
        let daemon = makeDaemon(output)

        await daemon.receive(hook("com.openai.codex-cli", "one", .working, timestamp: 10, expiry: 100))
        await daemon.receive(hook("com.openai.codex-cli", "one", nil, timestamp: 20))
        await daemon.receive(hook("com.openai.codex-cli", "one", .attention, timestamp: 15, expiry: 100))

        await assertOutput(output, .openai, nil)
    }

    func testMaintenanceRetriesFailedRendererAndShutdownTurnsBothOff() async {
        let output = RecordingOutput()
        await output.failNext()
        let daemon = makeDaemon(output)
        await daemon.applicationChanged("com.openai.codex", open: true)
        await daemon.applicationChanged("com.anthropic.claudefordesktop", open: true)
        await assertOutput(output, .claude, .ready)
        await daemon.maintain()
        await assertOutput(output, .openai, .ready)
        await daemon.shutdown()
        await assertOutput(output, .openai, nil)
        await assertOutput(output, .claude, nil)
    }

    func testMaintenanceUsesProbePathForBothProfiles() async {
        let renders = RecordingOutput()
        let probes = RecordingOutput()
        let daemon = Daemon(renderers: renders.renderers, maintenanceRenderers: probes.renderers,
                            now: { Date(timeIntervalSince1970: 0) })
        await daemon.applicationChanged("com.openai.codex", open: true)
        await daemon.applicationChanged("com.anthropic.claudefordesktop", open: true)
        await daemon.maintain()
        await assertOutput(probes, .openai, .ready)
        await assertOutput(probes, .claude, .ready)
        let ordinaryCount = await renders.count
        XCTAssertEqual(ordinaryCount, 2)
    }

    private func makeDaemon(_ output: RecordingOutput) -> Daemon {
        Daemon(renderers: output.renderers, now: { Date(timeIntervalSince1970: 0) })
    }

    private func hook(_ app: String, _ source: String, _ state: ActivityState?,
                      timestamp: Double = 0, expiry: Double? = nil) -> DaemonEvent {
        DaemonEvent(action: state == nil ? .clear : .update, sourceID: source, applicationID: app,
                    state: state, timestamp: Date(timeIntervalSince1970: timestamp),
                    expiresAt: expiry.map { Date(timeIntervalSince1970: $0) })
    }

    private func assertOutput(_ output: RecordingOutput, _ profile: StatusProfileID,
                              _ state: ActivityState?, file: StaticString = #filePath, line: UInt = #line) async {
        let value = await output.values[profile]
        XCTAssertEqual(value, StatusSnapshot(applicationOpen: state != nil, state: state), file: file, line: line)
    }
}

private actor RecordingOutput {
    var values: [StatusProfileID: StatusSnapshot] = [:]
    var count = 0
    private var shouldFail = false
    func failNext() { shouldFail = true }
    func record(_ profile: StatusProfileID, _ snapshot: StatusSnapshot) {
        count += 1
        if shouldFail { shouldFail = false; return }
        values[profile] = snapshot
    }
    nonisolated var renderers: [StatusProfileID: Daemon.Renderer] {
        [.openai: { await self.record(.openai, $0) }, .claude: { await self.record(.claude, $0) }]
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 0)
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
