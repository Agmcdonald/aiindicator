import XCTest
@testable import BlinkStatusCore

final class ChatGPTStateDetectorTests: XCTestCase {
    func testStopGeneratingControlMeansWorking() {
        let snapshot = AccessibilitySnapshot(labels: [], buttons: ["stop generating"], promptEnabled: true)

        XCTAssertEqual(ChatGPTStateDetector.detect(snapshot), .working)
    }

    func testApprovalControlMeansAttention() {
        let snapshot = AccessibilitySnapshot(
            labels: ["This action needs permission."],
            buttons: ["APPROVE"],
            promptEnabled: false
        )

        XCTAssertEqual(ChatGPTStateDetector.detect(snapshot), .attention)
    }

    func testEnabledPromptWithoutBusyControlMeansReady() {
        let snapshot = AccessibilitySnapshot(labels: [], buttons: [], promptEnabled: true)

        XCTAssertEqual(ChatGPTStateDetector.detect(snapshot), .ready)
    }

    func testExplicitQuestionInLatestResponseMeansAttention() {
        let snapshot = AccessibilitySnapshot(
            labels: ["The task is complete.", "Which option would you like me to use?"],
            buttons: [],
            promptEnabled: true
        )

        XCTAssertEqual(ChatGPTStateDetector.detect(snapshot), .attention)
    }

    func testUnknownSnapshotFallsBackToReady() {
        let snapshot = AccessibilitySnapshot(labels: ["Some unfamiliar status"], buttons: ["Share"], promptEnabled: false)

        XCTAssertEqual(ChatGPTStateDetector.detect(snapshot), .ready)
    }
}
