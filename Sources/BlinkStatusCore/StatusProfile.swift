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

    public init?(
        id: StatusProfileID,
        serialNumber: String,
        presenceColor: String,
        applicationIDs: Set<String>
    ) {
        guard Self.isCanonical(
            id: id,
            serialNumber: serialNumber,
            presenceColor: presenceColor,
            applicationIDs: applicationIDs
        ) else {
            return nil
        }

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
    )!

    public static let claude = StatusProfile(
        id: .claude,
        serialNumber: "2000A15D",
        presenceColor: "FF8000",
        applicationIDs: ["com.anthropic.claudefordesktop", "com.anthropic.claude-code"]
    )!

    public static let all = [openAI, claude]

    public static func profile(for applicationID: String) -> StatusProfile? {
        all.first { $0.applicationIDs.contains(applicationID) }
    }

    private static func isCanonical(
        id: StatusProfileID,
        serialNumber: String,
        presenceColor: String,
        applicationIDs: Set<String>
    ) -> Bool {
        switch id {
        case .openai:
            serialNumber == "2000A159" &&
                presenceColor == "FFFFFF" &&
                applicationIDs == ["com.openai.codex", "com.openai.codex-cli"]
        case .claude:
            serialNumber == "2000A15D" &&
                presenceColor == "FF8000" &&
                applicationIDs == ["com.anthropic.claudefordesktop", "com.anthropic.claude-code"]
        }
    }
}
