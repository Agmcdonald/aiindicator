import Foundation

public actor BlinkController {
    public static let executable = "/opt/homebrew/bin/blink1-tool"

    public private(set) var diagnostics = [String]()

    private let profile: StatusProfile
    private let runner: any CommandRunning
    private var deviceID: Int?
    private var lastRendered: LEDPair?
    private var isRendering = false
    private var pendingSnapshot: StatusSnapshot?
    private var pendingProbe = false

    public init(profile: StatusProfile, runner: any CommandRunning = CommandRunner()) {
        self.profile = profile
        self.runner = runner
    }

    public func render(_ snapshot: StatusSnapshot) async {
        await enqueue(snapshot, probe: false)
    }

    /// Rechecks device presence and repaints even when the pair is unchanged.
    /// A device unplugged and replugged between two maintenance passes never
    /// reports absent, yet its LEDs reset to dark, so a cached successful
    /// render is not evidence that the hardware is still showing that pair.
    public func maintain(_ snapshot: StatusSnapshot) async {
        await enqueue(snapshot, probe: true)
    }

    private func enqueue(_ snapshot: StatusSnapshot, probe: Bool) async {
        pendingSnapshot = snapshot
        pendingProbe = pendingProbe || probe
        guard !isRendering else { return }
        isRendering = true

        while let nextSnapshot = pendingSnapshot {
            pendingSnapshot = nil
            let shouldProbe = pendingProbe
            pendingProbe = false
            if shouldProbe {
                // Discard the cache on every maintenance pass: absence proves
                // the device is gone, and presence cannot prove it was never
                // power-cycled since the last successful render.
                guard await resolvedDeviceID() != nil else {
                    lastRendered = nil
                    continue
                }
                lastRendered = nil
            }
            await renderTransaction(LEDPair(snapshot: nextSnapshot, presenceColor: profile.presenceColor))
        }

        isRendering = false
    }

    private func renderTransaction(_ pair: LEDPair) async {
        guard pair != lastRendered else { return }
        guard let deviceID = await resolvedDeviceID() else { return }

        for command in pair.commands(deviceID: deviceID) {
            guard await runColorCommand(command) else {
                self.deviceID = nil
                return
            }
        }

        lastRendered = pair
    }

    private func resolvedDeviceID() async -> Int? {
        do {
            let result = try await runner.run(executable: Self.executable, arguments: ["--list"])
            guard result.exitCode == 0 else {
                deviceID = nil
                recordFailure()
                return nil
            }

            guard let discoveredDeviceID = Self.deviceID(in: result.stdout, serialNumber: profile.serialNumber) else {
                deviceID = nil
                return nil
            }

            if let deviceID, deviceID == discoveredDeviceID {
                return deviceID
            }
            lastRendered = nil
            deviceID = discoveredDeviceID
            return discoveredDeviceID
        } catch {
            deviceID = nil
            recordFailure()
            return nil
        }
    }

    private func runColorCommand(_ command: ColorCommand) async -> Bool {
        do {
            let result = try await runner.run(executable: Self.executable, arguments: command.arguments)
            guard result.exitCode == 0 else {
                recordFailure()
                return false
            }
            return true
        } catch {
            recordFailure()
            return false
        }
    }

    private func recordFailure() {
        diagnostics.append("blink1-tool command failed")
    }

    private static func deviceID(in listOutput: String, serialNumber: String) -> Int? {
        let serialToken = "serialnum:\(serialNumber)"
        for line in listOutput.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "(" || $0 == ")" })
            guard fields.contains(where: { $0 == serialToken }) else { continue }
            guard let idRange = line.range(of: "id:") else { continue }
            let digits = line[idRange.upperBound...].prefix(while: \.isNumber)
            if let id = Int(digits) {
                return id
            }
        }
        return nil
    }
}

private struct LEDPair: Equatable {
    let first: String
    let second: String

    init(snapshot: StatusSnapshot, presenceColor: String) {
        guard snapshot.applicationOpen else {
            first = "000000"
            second = "000000"
            return
        }

        first = presenceColor
        switch snapshot.state {
        case .ready, nil:
            second = "00FF00"
        case .working:
            second = "FFD000"
        case .attention:
            second = "FF0000"
        }
    }

    func commands(deviceID: Int) -> [ColorCommand] {
        [
            ColorCommand(deviceID: deviceID, led: 1, color: first),
            ColorCommand(deviceID: deviceID, led: 2, color: second),
        ]
    }
}

private struct ColorCommand {
    let deviceID: Int
    let led: Int
    let color: String

    var arguments: [String] {
        ["--id", String(deviceID), "--led", String(led), "--rgb", color, "-m", "120"]
    }
}
