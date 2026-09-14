import Foundation

public actor StatusStore {
    private var openApplications = Set<String>()
    private var activeSignals = [String: SourceEvent]()

    public init() {}

    public func apply(_ event: SourceEvent) {
        openApplications.insert(event.applicationID)
        activeSignals[event.sourceID] = event
    }

    public func clear(sourceID: String) {
        activeSignals.removeValue(forKey: sourceID)
    }

    public func clear(applicationID: String) {
        openApplications.remove(applicationID)
        activeSignals = activeSignals.filter { $0.value.applicationID != applicationID }
    }

    public func expire(now: Date) {
        activeSignals = activeSignals.filter { event in
            guard let expiresAt = event.value.expiresAt else { return true }
            return expiresAt > now
        }
    }

    public func snapshot(now: Date) -> StatusSnapshot {
        expire(now: now)

        guard !openApplications.isEmpty else {
            return StatusSnapshot(applicationOpen: false, state: nil)
        }

        let state = activeSignals.values.map(\.state).max { $0.rawValue < $1.rawValue } ?? .ready
        return StatusSnapshot(applicationOpen: true, state: state)
    }
}
