import XCTest
import BlinkStatusCore
@testable import blink_statusd

final class NativeMonitorTests: XCTestCase {
    @MainActor
    func testApplicationScanFiltersUnknownAppsAndDetectsTermination() async {
        var running = [RunningApplication(bundleID: "unknown", processID: 1),
                       RunningApplication(bundleID: "com.openai.codex", processID: 2)]
        var changes: [ApplicationPresenceChange] = []
        let monitor = ApplicationMonitor(running: { running }, onChange: { changes.append($0) })
        monitor.start()
        XCTAssertEqual(changes, [.init(applicationID: "com.openai.codex", processID: 2)])
        monitor.reconcile()
        XCTAssertEqual(changes.count, 1)
        running = [.init(bundleID: "com.anthropic.claudefordesktop", processID: 3)]
        monitor.reconcile()
        XCTAssertTrue(changes.contains(.init(applicationID: "com.openai.codex", processID: nil)))
        XCTAssertTrue(changes.contains(.init(applicationID: "com.anthropic.claudefordesktop", processID: 3)))
        monitor.stop()
    }

    func testAccessibilityThrottleDeduplicationAndLostTrustClearsState() async {
        let input = SampleInput()
        let output = SampleOutput()
        let monitor = AccessibilityMonitor(read: { input.read() }, onChange: { await output.record($0) })
        input.snapshot = .init(labels: [], buttons: ["Stop generating"], promptEnabled: false)
        await monitor.sample(at: 0)
        await monitor.sample(at: 0.2)
        let first = await output.values
        XCTAssertEqual(first, [.working])
        XCTAssertEqual(input.readCount, 1)
        await monitor.sample(at: 0.5)
        let unchanged = await output.values
        XCTAssertEqual(unchanged, [.working])
        input.snapshot = .init(labels: [], buttons: [], promptEnabled: true)
        await monitor.sample(at: 1)
        input.snapshot = nil
        await monitor.sample(at: 1.5)
        let final = await output.values
        XCTAssertEqual(final, [.working, .ready, nil])
    }
}

private final class SampleInput: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AccessibilitySnapshot?
    private var count = 0
    var snapshot: AccessibilitySnapshot? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
    var readCount: Int { lock.withLock { count } }
    func read() -> AccessibilitySnapshot? {
        lock.withLock { count += 1; return value }
    }
}

private actor SampleOutput {
    var values: [ActivityState?] = []
    func record(_ value: ActivityState?) { values.append(value) }
}
