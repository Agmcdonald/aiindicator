import Foundation

public enum EventAction: String, Codable, Sendable {
    case update
    case clear
}

public struct DaemonEvent: Codable, Sendable {
    public let action: EventAction
    public let sourceID: String
    public let applicationID: String
    public let state: ActivityState?
    public let timestamp: Date
    public let expiresAt: Date?

    public init(
        action: EventAction,
        sourceID: String,
        applicationID: String,
        state: ActivityState?,
        timestamp: Date,
        expiresAt: Date?
    ) {
        self.action = action
        self.sourceID = sourceID
        self.applicationID = applicationID
        self.state = state
        self.timestamp = timestamp
        self.expiresAt = expiresAt
    }

    public func encodedLine() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }

    public static func decodeLine(_ line: Data) throws -> DaemonEvent {
        guard line.last == 0x0A else {
            throw SocketProtocolError.missingNewline
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let event = try decoder.decode(DaemonEvent.self, from: line.dropLast())
        try event.validate()
        return event
    }

    private func validate() throws {
        guard !sourceID.isEmpty, !applicationID.isEmpty else {
            throw SocketProtocolError.missingIdentity
        }

        switch action {
        case .update:
            guard state != nil else { throw SocketProtocolError.missingState }
            guard expiresAt != nil else { throw SocketProtocolError.missingExpiry }
        case .clear:
            guard state == nil else { throw SocketProtocolError.unexpectedState }
            guard expiresAt == nil else { throw SocketProtocolError.unexpectedExpiry }
        }
    }
}

public enum SocketProtocolError: Error, Sendable {
    case missingNewline
    case missingIdentity
    case missingState
    case unexpectedState
    case missingExpiry
    case unexpectedExpiry
}
