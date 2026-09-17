import Foundation

public enum StatusProfileID: String, CaseIterable, Sendable {
    case openai
    case claude
}

public struct StatusProfile: Equatable, Sendable {
    public let id: StatusProfileID
    public let serialNumber: String
    public let presenceColor: String
    public let applicationIDs: Set<String>

    public init(
        id: StatusProfileID,
        serialNumber: String,
        presenceColor: String,
        applicationIDs: Set<String>
    ) {
        precondition(!serialNumber.isEmpty, "A status profile requires a serial number")
        precondition(
            Self.isUppercaseRGB(presenceColor),
            "A status profile presence color must be six uppercase RGB hex characters"
        )
        precondition(!applicationIDs.isEmpty, "A status profile requires at least one application ID")

        self.id = id
        self.serialNumber = serialNumber
        self.presenceColor = presenceColor
        self.applicationIDs = applicationIDs
    }

    public static let openAI = StatusProfile(
        id: .openai,
        serialNumber: "2000A159",
        presenceColor: "FFFFFF",
        applicationIDs: ["com.openai.codex", "com.openai.codex-cli"]
    )

    public static let claude = StatusProfile(
        id: .claude,
        serialNumber: "2000A15D",
        presenceColor: "FF8000",
        applicationIDs: ["com.anthropic.claudefordesktop", "com.anthropic.claude-code"]
    )

    public static let all = [openAI, claude]

    public static func profile(for applicationID: String) -> StatusProfile? {
        all.first { $0.applicationIDs.contains(applicationID) }
    }

    private static func isUppercaseRGB(_ value: String) -> Bool {
        value.utf8.count == 6 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70)
        }
    }
}
