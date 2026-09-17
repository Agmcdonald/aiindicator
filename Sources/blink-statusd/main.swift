import BlinkStatusCore
import AppKit
import Darwin

@main
struct BlinkStatusDaemon {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--request-accessibility") {
            let trusted = AccessibilityMonitor.requestTrust()
            print(trusted ? "Accessibility access is enabled." : "Enable blink-statusd in System Settings > Privacy & Security > Accessibility.")
            return
        }
        let runtime = DaemonRuntime()
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try runtime.start()
                await runtime.waitForTermination()
                exit(0)
            } catch {
                // Diagnostics deliberately exclude event payloads and Accessibility text.
                fputs("blink-statusd could not start its local event socket.\n", stderr)
                exit(1)
            }
        }
        // Workspace notifications need the native application run loop, even
        // though this background helper has no windows or Dock icon.
        application.run()
    }
}

@MainActor
private final class DaemonRuntime {
    private let daemon = Daemon.live()
    private var server: UnixSocketServer?
    private var applications: ApplicationMonitor?
    private var accessibility: [String: AccessibilityMonitor] = [:]
    private var lifecycle: Task<Void, Never>?
    private var maintenance: Task<Void, Never>?
    private var signals: [DispatchSourceSignal] = []
    private var finished: CheckedContinuation<Void, Never>?
    private var stopping = false

    func start() throws {
        let daemon = daemon
        let server = UnixSocketServer { await daemon.receive($0) }
        try server.start()
        self.server = server
        applications = ApplicationMonitor { [weak self] change in self?.applicationChanged(change) }
        applications?.start()
        maintenance = Task {
            while !Task.isCancelled {
                await daemon.maintain()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in Task { @MainActor in await self?.stop() } }
            source.resume()
            signals.append(source)
        }
    }

    private func applicationChanged(_ change: ApplicationPresenceChange) {
        // Preserve launch/termination order across awaits before starting samples.
        let previous = lifecycle
        lifecycle = Task { [weak self] in
            await previous?.value
            guard let self, !stopping else { return }
            if let old = accessibility.removeValue(forKey: change.applicationID) { await old.stop() }
            await daemon.applicationChanged(change.applicationID, open: change.processID != nil)
            if let processID = change.processID {
                let daemon = daemon
                let monitor = AccessibilityMonitor(processID: processID) { state in
                    await daemon.accessibilityChanged(change.applicationID, state: state)
                }
                accessibility[change.applicationID] = monitor
                await monitor.start()
            }
        }
    }

    func waitForTermination() async {
        guard !stopping else { return }
        await withCheckedContinuation { finished = $0 }
    }

    private func stop() async {
        guard !stopping else { return }
        stopping = true
        applications?.stop()
        maintenance?.cancel()
        server?.stop()
        await lifecycle?.value
        for monitor in accessibility.values { await monitor.stop() }
        accessibility.removeAll()
        await daemon.shutdown()
        for signal in signals { signal.cancel() }
        signals.removeAll()
        finished?.resume()
        finished = nil
    }
}
