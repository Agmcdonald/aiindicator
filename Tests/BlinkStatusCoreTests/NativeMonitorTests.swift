import XCTest
import BlinkStatusCore
import ApplicationServices
@testable import blink_statusd

final class NativeMonitorTests: XCTestCase {
    func testNativeReaderConfiguresEveryElementBeforeItsQuery() {
        let root = AXUIElementCreateApplication(1)
        let child = AXUIElementCreateSystemWide()
        var configured = Set<CFHashCode>()
        var queried: [CFHashCode] = []
        let snapshot = AccessibilityTreeReader.snapshot(root: root, setTimeout: { element, timeout in
            XCTAssertEqual(timeout, 0.05)
            configured.insert(CFHash(element))
            return .success
        }, readAttributes: { element, _ in
            XCTAssertTrue(configured.contains(CFHash(element)), "Every queried element needs its own IPC timeout")
            queried.append(CFHash(element))
            if CFEqual(element, root) {
                return [kAXApplicationRole, "", "", "", true, [child], ""]
            }
            return [kAXButtonRole, "Stop generating", "", "", true, [AXUIElement](), ""]
        })
        XCTAssertEqual(queried, [CFHash(root), CFHash(child)])
        XCTAssertEqual(snapshot.map(ChatGPTStateDetector.detect), .working)
    }

    func testNativeReaderDoesNotQueryChildWhenTimeoutConfigurationFails() {
        let root = AXUIElementCreateApplication(1)
        let child = AXUIElementCreateSystemWide()
        var queriedChild = false
        _ = AccessibilityTreeReader.snapshot(root: root, setTimeout: { element, _ in
            CFEqual(element, child) ? .cannotComplete : .success
        }, readAttributes: { element, _ in
            if CFEqual(element, child) { queriedChild = true }
            return [kAXApplicationRole, "", "", "", true, CFEqual(element, root) ? [child] : [], ""]
        })
        XCTAssertFalse(queriedChild)
    }

    @MainActor
    func testSuspendedOpenAIRenderDoesNotDelayClaudeLifecycleOrSampling() async {
        let blocked = expectation(description: "OpenAI rendering suspended")
        let claudeStarted = expectation(description: "Claude sampling started")
        let claudeStopped = expectation(description: "Claude sampling stopped")
        let gate = RenderGate()
        let daemon = Daemon(renderers: [.openai: { snapshot in
            if snapshot.applicationOpen { blocked.fulfill(); await gate.wait() }
        }, .claude: { _ in }])
        let runtime = DaemonRuntime(daemon: daemon, makeMonitor: { pid, _ in
            LifecycleMonitor(started: pid == 3 ? claudeStarted : nil, stopped: pid == 3 ? claudeStopped : nil)
        })
        runtime.applicationChanged(.init(applicationID: "com.openai.codex", processID: 2))
        await fulfillment(of: [blocked], timeout: 1)
        runtime.applicationChanged(.init(applicationID: "com.anthropic.claudefordesktop", processID: 3))
        runtime.applicationChanged(.init(applicationID: "com.anthropic.claudefordesktop", processID: nil))
        await fulfillment(of: [claudeStarted, claudeStopped], timeout: 1, enforceOrder: true)
        await gate.release()
        await runtime.stop()
    }

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

private actor RenderGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private actor LifecycleMonitor: AccessibilityMonitoring {
    let started: XCTestExpectation?
    let stopped: XCTestExpectation?
    init(started: XCTestExpectation?, stopped: XCTestExpectation?) {
        self.started = started
        self.stopped = stopped
    }
    func start() { started?.fulfill() }
    func stop() { stopped?.fulfill() }
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
