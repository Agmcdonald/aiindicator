import XCTest
@testable import BlinkStatusCore

final class StatusProfileTests: XCTestCase {
    func testKnownApplicationIDsRouteToTheirImmutableProfiles() {
        assertProfile(
            StatusProfile.profile(for: "com.openai.codex"),
            id: .openai,
            serialNumber: "2000A159",
            presenceColor: "FFFFFF"
        )
        assertProfile(
            StatusProfile.profile(for: "com.openai.codex-cli"),
            id: .openai,
            serialNumber: "2000A159",
            presenceColor: "FFFFFF"
        )
        assertProfile(
            StatusProfile.profile(for: "com.anthropic.claudefordesktop"),
            id: .claude,
            serialNumber: "2000A15D",
            presenceColor: "FF8000"
        )
        assertProfile(
            StatusProfile.profile(for: "com.anthropic.claude-code"),
            id: .claude,
            serialNumber: "2000A15D",
            presenceColor: "FF8000"
        )
    }

    func testUnknownApplicationIDDoesNotRouteToADevice() {
        XCTAssertNil(StatusProfile.profile(for: "com.example.unknown"))
    }

    private func assertProfile(
        _ profile: StatusProfile?,
        id: StatusProfileID,
        serialNumber: String,
        presenceColor: String
    ) {
        XCTAssertEqual(profile?.id, id)
        XCTAssertEqual(profile?.serialNumber, serialNumber)
        XCTAssertEqual(profile?.presenceColor, presenceColor)
    }
}
