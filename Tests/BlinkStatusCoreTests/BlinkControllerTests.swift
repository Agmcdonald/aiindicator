import XCTest
@testable import BlinkStatusCore

final class BlinkControllerTests: XCTestCase {
    func testOffRendersBothLEDsBlackOnResolvedDevice() async {
        let runner = RecordingRunner(listOutput: deviceList)
        let controller = BlinkController(runner: runner)

        await controller.render(StatusSnapshot(applicationOpen: false, state: nil))

        let invocations = await runner.invocations()
        XCTAssertEqual(invocations, [
            CommandInvocation(arguments: ["--list"]),
            CommandInvocation(arguments: ["--id", "0", "--led", "1", "--rgb", "000000", "-m", "120"]),
            CommandInvocation(arguments: ["--id", "0", "--led", "2", "--rgb", "000000", "-m", "120"]),
        ])
    }

    func testReadyRendersWhiteAndGreenOnResolvedDevice() async {
        let runner = RecordingRunner(listOutput: deviceList)
        let controller = BlinkController(runner: runner)

        await controller.render(snapshot(for: .ready))

        let invocations = await runner.invocations()
        XCTAssertEqual(invocations, [
            CommandInvocation(arguments: ["--list"]),
            CommandInvocation(arguments: ["--id", "0", "--led", "1", "--rgb", "FFFFFF", "-m", "120"]),
            CommandInvocation(arguments: ["--id", "0", "--led", "2", "--rgb", "00FF00", "-m", "120"]),
        ])
    }

    func testWorkingRendersWhiteAndAmberOnResolvedDevice() async {
        let runner = RecordingRunner(listOutput: deviceList)
        let controller = BlinkController(runner: runner)

        await controller.render(snapshot(for: .working))

        let invocations = await runner.invocations()
        XCTAssertEqual(invocations, [
            CommandInvocation(arguments: ["--list"]),
            CommandInvocation(arguments: ["--id", "0", "--led", "1", "--rgb", "FFFFFF", "-m", "120"]),
            CommandInvocation(arguments: ["--id", "0", "--led", "2", "--rgb", "FFD000", "-m", "120"]),
        ])
    }

    func testAttentionRendersWhiteAndRedOnResolvedDevice() async {
        let runner = RecordingRunner(listOutput: deviceList)
        let controller = BlinkController(runner: runner)

        await controller.render(snapshot(for: .attention))

        let invocations = await runner.invocations()
        XCTAssertEqual(invocations, [
            CommandInvocation(arguments: ["--list"]),
            CommandInvocation(arguments: ["--id", "0", "--led", "1", "--rgb", "FFFFFF", "-m", "120"]),
            CommandInvocation(arguments: ["--id", "0", "--led", "2", "--rgb", "FF0000", "-m", "120"]),
        ])
    }

    func testMissingTargetSerialSendsNoColorCommands() async {
        let runner = RecordingRunner(listOutput: "blink(1) list:\nid:1 - serialnum:OTHER (mk2) fw version:204")
        let controller = BlinkController(runner: runner)

        await controller.render(snapshot(for: .ready))

        let invocations = await runner.invocations()
        XCTAssertEqual(invocations, [CommandInvocation(arguments: ["--list"])])
    }

    func testRenderingUnchangedSnapshotTwiceDoesNotRunAnyAdditionalCommands() async {
        let runner = RecordingRunner(listOutput: deviceList)
        let controller = BlinkController(runner: runner)
        let snapshot = snapshot(for: .working)

        await controller.render(snapshot)
        let callsAfterFirstRender = await runner.invocations()
        await controller.render(snapshot)

        let finalInvocations = await runner.invocations()
        XCTAssertEqual(finalInvocations, callsAfterFirstRender)
    }

    func testRunnerErrorIsSwallowedAndRecordedWithoutUnderlyingErrorText() async {
        let runner = RecordingRunner(error: TestError.secret("serial 2000A159 must not escape"))
        let controller = BlinkController(runner: runner)

        await controller.render(snapshot(for: .ready))

        let diagnostics = await controller.diagnostics
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertFalse(diagnostics.joined(separator: " ").contains("2000A159"))
        let invocations = await runner.invocations()
        XCTAssertEqual(invocations, [CommandInvocation(arguments: ["--list"])])
    }

    func testColorFailureInvalidatesDeviceAndRetriesUnrenderedPairAfterRediscovery() async {
        let runner = RecordingRunner(
            listOutput: deviceList,
            plannedResults: [.success(CommandResult(exitCode: 1, stdout: "", stderr: "unavailable"))]
        )
        let controller = BlinkController(runner: runner)
        let snapshot = snapshot(for: .ready)

        await controller.render(snapshot)
        await controller.render(snapshot)

        let invocations = await runner.invocations()
        XCTAssertEqual(invocations, [
            CommandInvocation(arguments: ["--list"]),
            CommandInvocation(arguments: ["--id", "0", "--led", "1", "--rgb", "FFFFFF", "-m", "120"]),
            CommandInvocation(arguments: ["--list"]),
            CommandInvocation(arguments: ["--id", "0", "--led", "1", "--rgb", "FFFFFF", "-m", "120"]),
            CommandInvocation(arguments: ["--id", "0", "--led", "2", "--rgb", "00FF00", "-m", "120"]),
        ])
    }

    private func snapshot(for state: ActivityState) -> StatusSnapshot {
        StatusSnapshot(applicationOpen: true, state: state)
    }
}

private let deviceList = "blink(1) list:\nid:0 - serialnum:2000A159 (mk2) fw version:204"

private struct CommandInvocation: Equatable, Sendable {
    let executable: String
    let arguments: [String]

    init(executable: String = "/opt/homebrew/bin/blink1-tool", arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

private actor RecordingRunner: CommandRunning {
    private let listOutput: String
    private let error: Error?
    private var plannedResults: [Result<CommandResult, Error>]
    private var recordedInvocations = [CommandInvocation]()

    init(
        listOutput: String = "",
        error: Error? = nil,
        plannedResults: [Result<CommandResult, Error>] = []
    ) {
        self.listOutput = listOutput
        self.error = error
        self.plannedResults = plannedResults
    }

    func run(executable: String, arguments: [String]) async throws -> CommandResult {
        recordedInvocations.append(CommandInvocation(executable: executable, arguments: arguments))

        if let error {
            throw error
        }

        if arguments == ["--list"] {
            return CommandResult(exitCode: 0, stdout: listOutput, stderr: "")
        }

        if !plannedResults.isEmpty {
            return try plannedResults.removeFirst().get()
        }

        return CommandResult(exitCode: 0, stdout: "", stderr: "")
    }

    func invocations() -> [CommandInvocation] {
        recordedInvocations
    }
}

private enum TestError: Error {
    case secret(String)
}
