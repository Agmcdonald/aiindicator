import AppKit

struct RunningApplication: Sendable {
    let bundleID: String
    let processID: pid_t
}

struct ApplicationPresenceChange: Equatable, Sendable {
    let applicationID: String
    let processID: pid_t?
}

@MainActor
final class ApplicationMonitor {
    private let running: () -> [RunningApplication]
    private let onChange: (ApplicationPresenceChange) -> Void
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var previous: [String: pid_t] = [:]

    init(running: @escaping () -> [RunningApplication] = {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier, !app.isTerminated else { return nil }
            return RunningApplication(bundleID: id, processID: app.processIdentifier)
        }
    }, center: NotificationCenter = NSWorkspace.shared.notificationCenter,
         onChange: @escaping (ApplicationPresenceChange) -> Void) {
        self.running = running
        self.center = center
        self.onChange = onChange
    }

    func start() {
        guard observers.isEmpty else { return }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.reconcile() }
            })
        }
        reconcile()
    }

    func reconcile() {
        var current: [String: pid_t] = [:]
        for app in running() where Daemon.desktopIDs.contains(app.bundleID) {
            // Stable selection if an application temporarily has two processes.
            current[app.bundleID] = min(current[app.bundleID] ?? app.processID, app.processID)
        }
        for id in Set(previous.keys).union(current.keys).sorted() where previous[id] != current[id] {
            onChange(ApplicationPresenceChange(applicationID: id, processID: current[id]))
        }
        previous = current
    }

    func stop() {
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
        previous.removeAll()
    }
}
