import Foundation
import XCTest
@testable import BlinkStatusCore

final class CommandRunnerTests: XCTestCase {
    func testTimeoutDrainsContinuousStandardOutputAndTerminates() async throws {
        let runner = CommandRunner(timeout: .milliseconds(100), terminationGracePeriod: .milliseconds(100))
        let started = ContinuousClock.now

        let result = try await runner.run(executable: "/usr/bin/yes", arguments: ["output"])

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertFalse(result.stdout.isEmpty)
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
    }

    func testTimeoutDrainsContinuousStandardErrorAndTerminates() async throws {
        let runner = CommandRunner(timeout: .milliseconds(100), terminationGracePeriod: .milliseconds(100))

        let result = try await runner.run(executable: "/bin/sh", arguments: ["-c", "yes error >&2"])

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertFalse(result.stderr.isEmpty)
    }
}
