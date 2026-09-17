import XCTest
@testable import BlinkStatusCore

final class BlinkControllerTests: XCTestCase {
    func testOffRendersBothLEDsBlackOnResolvedDevice() async {
        let runner = RecordingRunner(listOutput: deviceList)
        let controller = BlinkController(profile: .openAI, runner: runner)

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
        let controller = BlinkController(profile: .openAI, runner: runner)

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
        let controller = BlinkController(profile: .openAI, runner: runner)

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
        let controller = BlinkController(profile: .openAI, runner: runner)

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
        let controller = BlinkController(profile: .openAI, runner: runner)

        await controller.render(snapshot(for: .ready))

        let invocations = await runner.invocations()
        XCTAssertEqual(invocations, [CommandInvocation(arguments: ["--list"])])
    }

    func testSerialWithTargetPrefixSendsNoColorCommands() async {
        let runner = RecordingRunner(listOutput: "blink(1) list:\nid:1 - serialnum:2000A1590 (mk2) fw version:204")
        let controller = BlinkController(profile: .openAI, runner: runner)

        await controller.render(snapshot(for: .ready))

        let invocations = await runner.invocations()
        XCTAssertEqual(invocations, [CommandInvocation(arguments: ["--list"])])
    }

    func testRenderingUnchangedSnapshotTwiceDoesNotRunAnyAdditionalCommands() async {
        let runner = RecordingRunner(listOutput: deviceList)
        let controller = BlinkController(profile: .openAI, runner: runner)
        let snapshot = snapshot(for: .working)

        await controller.render(snapshot)
        let callsAfterFirstRender = await runner.invocations()
        await controller.render(snapshot)

        let finalInvocations = await runner.invocations()
        XCTAssertEqual(finalInvocations, callsAfterFirstRender)
    }

    func testConcurrentIdenticalRendersDoNotDuplicateCommandsWhileRunnerIsSuspended() async {
        let runner = SuspendingRunner(listOutput: deviceList)
        let controller = BlinkController(profile: .openAI, runner: runner)
        let snapshot = snapshot(for: .working)

        let firstRender = Task { await controller.render(snapshot) }
        await runner.waitUntilFirstListStarts()
        let secondRender = Task { await controller.render(snapshot) }
        for _ in 0..<10 {
            await Task.yield()
        }

        let invocationsWhileSuspended = await runner.invocations()
        XCTAssertEqual(invocationsWhileSuspended, [CommandInvocation(arguments: ["--list"])])

        await runner.resumeFirstList()
        await firstRender.value
        await secondRender.value

        let finalInvocations = await runner.invocations()
        XCTAssertEqual(finalInvocations, [
            CommandInvocation(arguments: ["--list"]),
            CommandInvocation(arguments: ["--id", "0", "--led", "1", "--rgb", "FFFFFF", "-m", "120"]),
            CommandInvocation(arguments: ["--id", "0", "--led", "2", "--rgb", "FFD000", "-m", "120"]),
        ])
    }

    func testRunnerErrorIsSwallowedAndRecordedWithoutUnderlyingErrorText() async {
        let runner = RecordingRunner(error: TestError.secret("serial 2000A159 must not escape"))
        let controller = BlinkController(profile: .openAI, runner: runner)

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
        let controller = BlinkController(profile: .openAI, runner: runner)
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

    func testClaudeControllerSelectsClaudeDeviceAndUsesOrangePresenceColor() async {
        let runner = RecordingRunner(listOutput: deviceList)
        let controller = BlinkController(profile: .claude, runner: runner)

        await controller.render(snapshot(for: .ready))

        let invocations = await runner.invocations()
        XCTAssertEqual(invocations, [
            CommandInvocation(arguments: ["--list"]),
            CommandInvocation(arguments: ["--id", "1", "--led", "1", "--rgb", "FF8000", "-m", "120"]),
            CommandInvocation(arguments: ["--id", "1", "--led", "2", "--rgb", "00FF00", "-m", "120"]),
        ])
    }

    func testControllersDiscoverAndSuppressDuplicatesIndependently() async {
        let runner = RecordingRunner(listOutput: deviceList)
        let openAIController = BlinkController(profile: .openAI, runner: runner)
        let claudeController = BlinkController(profile: .claude, runner: runner)
        let snapshot = snapshot(for: .ready)

        await openAIController.render(snapshot)
        await claudeController.render(snapshot)
        await openAIController.render(snapshot)
        await claudeController.render(snapshot)

        let invocations = await runner.invocations()
        XCTAssertEqual(invocations, [
            CommandInvocation(arguments: ["--list"]),
            CommandInvocation(arguments: ["--id", "0", "--led", "1", "--rgb", "FFFFFF", "-m", "120"]),
            CommandInvocation(arguments: ["--id", "0", "--led", "2", "--rgb", "00FF00", "-m", "120"]),
            CommandInvocation(arguments: ["--list"]),
            CommandInvocation(arguments: ["--id", "1", "--led", "1", "--rgb", "FF8000", "-m", "120"]),
            CommandInvocation(arguments: ["--id", "1", "--led", "2", "--rgb", "00FF00", "-m", "120"]),
        ])
    }

    private func snapshot(for state: ActivityState) -> StatusSnapshot {
        StatusSnapshot(applicationOpen: true, state: state)
    }
}

private let deviceList = """
blink(1) list:
id:0 - serialnum:2000A159 (mk2) fw version:204
id:1 - serialnum:2000A15D (mk2) fw version:204
"""

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

private actor SuspendingRunner: CommandRunning {
    private let listOutput: String
    private var recordedInvocations = [CommandInvocation]()
    private var listStarted = false
    private var listStartWaiters = [CheckedContinuation<Void, Never>]()
    private var firstListResume: CheckedContinuation<Void, Never>?

    init(listOutput: String) {
        self.listOutput = listOutput
    }

    func run(executable: String, arguments: [String]) async throws -> CommandResult {
        recordedInvocations.append(CommandInvocation(executable: executable, arguments: arguments))

        if arguments == ["--list"] {
            if !listStarted {
                listStarted = true
                let waiters = listStartWaiters
                listStartWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume()
                }
                await withCheckedContinuation { continuation in
                    firstListResume = continuation
                }
            }
            return CommandResult(exitCode: 0, stdout: listOutput, stderr: "")
        }

        return CommandResult(exitCode: 0, stdout: "", stderr: "")
    }

    func waitUntilFirstListStarts() async {
        guard !listStarted else { return }
        await withCheckedContinuation { continuation in
            listStartWaiters.append(continuation)
        }
    }

    func resumeFirstList() {
        firstListResume?.resume()
        firstListResume = nil
    }

    func invocations() -> [CommandInvocation] {
        recordedInvocations
    }
}

private enum TestError: Error {
    case secret(String)
}
