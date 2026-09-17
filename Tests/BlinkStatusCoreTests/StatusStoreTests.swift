import XCTest
@testable import BlinkStatusCore

final class StatusStoreTests: XCTestCase {
    func testNoOpenApplicationResolvesToOff() async {
        let store = StatusStore()

        let snapshot = await store.snapshot(now: date(0))

        XCTAssertEqual(snapshot, StatusSnapshot(applicationOpen: false, state: nil))
    }

    func testOpenApplicationWithoutTurnResolvesReady() async {
        let store = StatusStore()
        await store.setApplicationOpen("com.example.editor", open: true)
        await store.apply(SourceEvent(
            sourceID: "editor",
            applicationID: "com.example.editor",
            state: .working,
            timestamp: date(0),
            expiresAt: date(1)
        ))

        let snapshot = await store.snapshot(now: date(2))

        XCTAssertEqual(snapshot, StatusSnapshot(applicationOpen: true, state: .ready))
    }

    func testWorkingOverridesReady() async {
        let store = StatusStore()
        await store.apply(event(sourceID: "editor", applicationID: "com.example.editor", state: .ready, timestamp: 0))
        await store.apply(event(sourceID: "build", applicationID: "com.example.build", state: .working, timestamp: 0))

        let snapshot = await store.snapshot(now: date(1))

        XCTAssertEqual(snapshot, StatusSnapshot(applicationOpen: true, state: .working))
    }

    func testAttentionOverridesWorkingAcrossSources() async {
        let store = StatusStore()
        await store.apply(event(sourceID: "build", applicationID: "com.example.build", state: .working, timestamp: 0))
        await store.apply(event(sourceID: "review", applicationID: "com.example.review", state: .attention, timestamp: 0))

        let snapshot = await store.snapshot(now: date(1))

        XCTAssertEqual(snapshot, StatusSnapshot(applicationOpen: true, state: .attention))
    }

    func testClearingAttentionRevealsWorking() async {
        let store = StatusStore()
        await store.apply(event(sourceID: "build", applicationID: "com.example.build", state: .working, timestamp: 0))
        await store.apply(event(sourceID: "review", applicationID: "com.example.review", state: .attention, timestamp: 0))
        await store.clear(sourceID: "review")

        let snapshot = await store.snapshot(now: date(1))

        XCTAssertEqual(snapshot, StatusSnapshot(applicationOpen: true, state: .working))
    }

    func testExpiredEventIsRemoved() async {
        let store = StatusStore()
        await store.apply(SourceEvent(
            sourceID: "build",
            applicationID: "com.example.build",
            state: .working,
            timestamp: date(0),
            expiresAt: date(10)
        ))

        await store.expire(now: date(10))
        let snapshot = await store.snapshot(now: date(10))

        XCTAssertEqual(snapshot, StatusSnapshot(applicationOpen: false, state: nil))
    }

    func testLastCLISessionClearingTurnsProfileOff() async {
        let store = StatusStore()
        await store.apply(event(sourceID: "one", applicationID: "cli", state: .working, timestamp: 0))
        await store.apply(event(sourceID: "two", applicationID: "cli", state: .ready, timestamp: 0))
        await store.clear(sourceID: "one")
        let remaining = await store.snapshot(now: date(1))
        XCTAssertEqual(remaining, StatusSnapshot(applicationOpen: true, state: .ready))
        await store.clear(sourceID: "two")
        let empty = await store.snapshot(now: date(1))
        XCTAssertEqual(empty, StatusSnapshot(applicationOpen: false, state: nil))
    }

    func testGUIClosurePreservesIndependentCLISession() async {
        let store = StatusStore()
        await store.setApplicationOpen("gui", open: true)
        await store.apply(event(sourceID: "cli:1", applicationID: "cli", state: .working, timestamp: 0))
        await store.setApplicationOpen("gui", open: false)
        let result = await store.snapshot(now: date(1))
        XCTAssertEqual(result, StatusSnapshot(applicationOpen: true, state: .working))
    }

    func testClearingApplicationRemovesItsSources() async {
        let store = StatusStore()
        await store.apply(event(sourceID: "build", applicationID: "com.example.build", state: .working, timestamp: 0))
        await store.apply(event(sourceID: "review", applicationID: "com.example.build", state: .attention, timestamp: 0))
        await store.apply(event(sourceID: "editor", applicationID: "com.example.editor", state: .ready, timestamp: 0))
        await store.clear(applicationID: "com.example.build")

        let snapshot = await store.snapshot(now: date(1))

        XCTAssertEqual(snapshot, StatusSnapshot(applicationOpen: true, state: .ready))
    }

    private func event(sourceID: String, applicationID: String, state: ActivityState, timestamp: TimeInterval) -> SourceEvent {
        SourceEvent(
            sourceID: sourceID,
            applicationID: applicationID,
            state: state,
            timestamp: date(timestamp),
            expiresAt: nil
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
