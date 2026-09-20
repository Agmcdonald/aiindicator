import BlinkStatusCore
import Foundation

/// Routes events to independent profile queues. Slow or missing hardware in one
/// profile cannot delay the other profile's state updates or renders.
actor Daemon {
    typealias Renderer = @Sendable (StatusSnapshot) async -> Void
    static let desktopIDs: Set<String> = ["com.openai.codex", "com.anthropic.claudefordesktop"]
    private let channels: [StatusProfileID: ProfileChannel]
    private var stopped = false

    init(renderers: [StatusProfileID: Renderer], maintenanceRenderers: [StatusProfileID: Renderer] = [:],
         now: @escaping @Sendable () -> Date = { Date() }) {
        channels = Dictionary(uniqueKeysWithValues: StatusProfile.all.map { profile in
            let render = renderers[profile.id] ?? { _ in }
            return (profile.id, ProfileChannel(render: render,
                maintain: maintenanceRenderers[profile.id] ?? render, now: now))
        })
    }

    static func live() -> Daemon {
        var renderers: [StatusProfileID: Renderer] = [:]
        var maintenance: [StatusProfileID: Renderer] = [:]
        for profile in StatusProfile.all {
            let controller = BlinkController(profile: profile)
            renderers[profile.id] = { await controller.render($0) }
            maintenance[profile.id] = { await controller.maintain($0) }
        }
        return Daemon(renderers: renderers, maintenanceRenderers: maintenance)
    }

    func applicationChanged(_ applicationID: String, open: Bool) async {
        guard !stopped, Self.desktopIDs.contains(applicationID), let channel = channel(for: applicationID) else { return }
        await channel.enqueue(.application(applicationID, open))
    }

    func accessibilityChanged(_ applicationID: String, state: ActivityState?) async {
        guard !stopped, Self.desktopIDs.contains(applicationID), let channel = channel(for: applicationID) else { return }
        await channel.enqueue(.accessibility(applicationID, state))
    }

    func receive(_ event: DaemonEvent) async {
        guard !stopped, let channel = channel(for: event.applicationID) else { return }
        await channel.enqueue(.hook(event))
    }

    func maintain() async {
        guard !stopped else { return }
        await withTaskGroup(of: Void.self) { group in
            for channel in channels.values { group.addTask { await channel.enqueue(.refresh) } }
        }
    }

    func shutdown() async {
        guard !stopped else { return }
        stopped = true
        await withTaskGroup(of: Void.self) { group in
            for channel in channels.values { group.addTask { await channel.enqueue(.shutdown) } }
        }
    }

    private func channel(for applicationID: String) -> ProfileChannel? {
        guard let profile = StatusProfile.profile(for: applicationID) else { return nil }
        return channels[profile.id]
    }
}

private actor ProfileChannel {
    private static let maximumClockSkew: TimeInterval = 5 * 60
    private static let hookTimestampRetention: TimeInterval = 24 * 60 * 60

    enum Change: Sendable {
        case application(String, Bool)
        case accessibility(String, ActivityState?)
        case hook(DaemonEvent)
        case refresh
        case shutdown
    }

    private let store = StatusStore()
    private let render: Daemon.Renderer
    private let maintain: Daemon.Renderer
    private let now: @Sendable () -> Date
    private var openDesktopIDs = Set<String>()
    private var latestHookTimestamps = [String: Date]()
    private var tail: Task<Void, Never>?
    private var stopped = false

    init(render: @escaping Daemon.Renderer, maintain: @escaping Daemon.Renderer,
         now: @escaping @Sendable () -> Date) {
        self.render = render
        self.maintain = maintain
        self.now = now
    }

    func enqueue(_ change: Change) async {
        let previous = tail
        let task = Task {
            await previous?.value
            await self.perform(change)
        }
        tail = task
        await task.value
    }

    private func perform(_ change: Change) async {
        guard !stopped else { return }
        let timestamp = now()
        switch change {
        case let .application(applicationID, open):
            if open { openDesktopIDs.insert(applicationID) }
            else { openDesktopIDs.remove(applicationID) }
            await store.setApplicationOpen(applicationID, open: open)
        case let .accessibility(applicationID, state):
            guard openDesktopIDs.contains(applicationID) else { return }
            let source = "accessibility:\(applicationID)"
            if let state {
                await store.apply(SourceEvent(sourceID: source, applicationID: applicationID,
                    state: state, timestamp: timestamp, expiresAt: nil))
            } else {
                await store.clear(sourceID: source)
            }
        case let .hook(event):
            // Namespace caller-supplied source IDs so one application cannot clear
            // another application's session, even within the same profile.
            let source = "hook:\(event.applicationID):\(event.sourceID)"
            pruneHookTimestamps(now: timestamp)
            guard event.timestamp <= timestamp.addingTimeInterval(Self.maximumClockSkew) else { return }
            guard latestHookTimestamps[source].map({ event.timestamp >= $0 }) ?? true else { return }
            latestHookTimestamps[source] = event.timestamp
            if event.action == .clear {
                await store.clear(sourceID: source)
            } else if let state = event.state {
                await store.apply(SourceEvent(sourceID: source, applicationID: event.applicationID,
                    state: state, timestamp: event.timestamp, expiresAt: event.expiresAt))
            } else { return }
        case .refresh:
            pruneHookTimestamps(now: timestamp)
            await maintain(await store.snapshot(now: timestamp))
            return
        case .shutdown:
            stopped = true
            await render(StatusSnapshot(applicationOpen: false, state: nil))
            return
        }
        await render(await store.snapshot(now: timestamp))
    }

    private func pruneHookTimestamps(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.hookTimestampRetention)
        latestHookTimestamps = latestHookTimestamps.filter { $0.value >= cutoff }
    }
}
