import Foundation

public enum ActivityState: Int, Codable, Sendable {
    case ready
    case working
    case attention
}

public struct SourceEvent: Codable, Sendable {
    public let sourceID: String
    public let applicationID: String
    public let state: ActivityState
    public let timestamp: Date
    public let expiresAt: Date?

    public init(
        sourceID: String,
        applicationID: String,
        state: ActivityState,
        timestamp: Date,
        expiresAt: Date?
    ) {
        self.sourceID = sourceID
        self.applicationID = applicationID
        self.state = state
        self.timestamp = timestamp
        self.expiresAt = expiresAt
    }
}

public struct StatusSnapshot: Equatable, Sendable {
    public let applicationOpen: Bool
    public let state: ActivityState?

    public init(applicationOpen: Bool, state: ActivityState?) {
        self.applicationOpen = applicationOpen
        self.state = state
    }
}
