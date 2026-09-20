import Foundation
import XCTest
@testable import BlinkStatusCore

final class SocketProtocolTests: XCTestCase {
    func testUpdateEventEncodesAsOneNewlineDelimitedJSONObject() throws {
        let event = DaemonEvent(
            action: .update,
            sourceID: "codex:session-123",
            applicationID: "com.openai.codex",
            state: .working,
            timestamp: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 7_300)
        )

        let line = try event.encodedLine()

        XCTAssertEqual(line.last, 0x0A)
        let decoded = try DaemonEvent.decodeLine(line)
        XCTAssertEqual(decoded.action, .update)
        XCTAssertEqual(decoded.sourceID, "codex:session-123")
        XCTAssertEqual(decoded.applicationID, "com.openai.codex")
        XCTAssertEqual(decoded.state, .working)
        XCTAssertEqual(decoded.timestamp, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(decoded.expiresAt, Date(timeIntervalSince1970: 7_300))
    }

    func testClearEventAllowsNoState() throws {
        let event = DaemonEvent(
            action: .clear,
            sourceID: "codex:session-123",
            applicationID: "com.openai.codex",
            state: nil,
            timestamp: Date(timeIntervalSince1970: 100),
            expiresAt: nil
        )

        let decoded = try DaemonEvent.decodeLine(event.encodedLine())

        XCTAssertEqual(decoded.action, .clear)
        XCTAssertNil(decoded.state)
        XCTAssertNil(decoded.expiresAt)
    }

    func testDecodeRejectsUnknownActivityState() {
        let line = Data((#"{"action":"update","sourceID":"codex:session-123","applicationID":"com.openai.codex","state":99,"timestamp":100,"expiresAt":null}"# + "\n").utf8)

        XCTAssertThrowsError(try DaemonEvent.decodeLine(line))
    }

    func testDecodeUsesPythonStyleUnixEpochSeconds() throws {
        let line = Data((#"{"action":"update","sourceID":"codex:session-123","applicationID":"com.openai.codex","state":1,"timestamp":1700000000,"expiresAt":1700007200}"# + "\n").utf8)

        let event = try DaemonEvent.decodeLine(line)

        XCTAssertEqual(event.timestamp, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(event.expiresAt, Date(timeIntervalSince1970: 1_700_007_200))
    }

    func testUpdateWithoutExpiryIsRejected() {
        let line = Data((#"{"action":"update","sourceID":"codex:session-123","applicationID":"com.openai.codex-cli","state":1,"timestamp":100,"expiresAt":null}"# + "\n").utf8)

        XCTAssertThrowsError(try DaemonEvent.decodeLine(line)) { error in
            guard case SocketProtocolError.missingExpiry = error else {
                return XCTFail("Expected missingExpiry, got \(error)")
            }
        }
    }

    func testClearWithExpiryIsRejected() {
        let line = Data((#"{"action":"clear","sourceID":"codex:session-123","applicationID":"com.openai.codex-cli","state":null,"timestamp":100,"expiresAt":200}"# + "\n").utf8)

        XCTAssertThrowsError(try DaemonEvent.decodeLine(line)) { error in
            guard case SocketProtocolError.unexpectedExpiry = error else {
                return XCTFail("Expected unexpectedExpiry, got \(error)")
            }
        }
    }

    func testWorkingLeaseLongerThanTwoHoursIsRejected() {
        let line = Data((#"{"action":"update","sourceID":"codex:session-123","applicationID":"com.openai.codex-cli","state":1,"timestamp":100,"expiresAt":7301}"# + "\n").utf8)

        XCTAssertThrowsError(try DaemonEvent.decodeLine(line))
    }

    func testLeaseMustExpireAfterItsTimestamp() {
        let line = Data((#"{"action":"update","sourceID":"codex:session-123","applicationID":"com.openai.codex-cli","state":2,"timestamp":100,"expiresAt":100}"# + "\n").utf8)

        XCTAssertThrowsError(try DaemonEvent.decodeLine(line))
    }
}
