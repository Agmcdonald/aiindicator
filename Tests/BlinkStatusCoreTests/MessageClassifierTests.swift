import XCTest
@testable import BlinkStatusCore

final class MessageClassifierTests: XCTestCase {
    func testDirectQuestionsAndExplicitInputRequestsNeedInput() {
        let messages = [
            "Which option would you like me to use?",
            "Please attach the missing image so I can continue.",
            "I need your approval before proceeding.",
            "Choose A or B.",
        ]

        for message in messages {
            XCTAssertTrue(MessageClassifier.needsInput(message), message)
        }
    }

    func testCompletedAndCourtesyMessagesDoNotNeedInput() {
        let messages = [
            "The installation is complete.",
            "Here is the requested summary.",
            "Let me know if you want anything else.",
            "The tests passed; no further action is required.",
        ]

        for message in messages {
            XCTAssertFalse(MessageClassifier.needsInput(message), message)
        }
    }

    func testWhitespaceAndCaseAreNormalized() {
        XCTAssertTrue(MessageClassifier.needsInput("  PLEASE ATTACH the missing image  "))
    }

    func testCourtesyQuestionDoesNotNeedInput() {
        XCTAssertFalse(MessageClassifier.needsInput("  LET ME KNOW if you want anything else?  "))
    }
}
