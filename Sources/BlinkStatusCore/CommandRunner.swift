import Foundation
import Darwin

public struct CommandResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CommandRunning: Sendable {
    func run(executable: String, arguments: [String]) async throws -> CommandResult
}

public struct CommandRunner: CommandRunning {
    private let timeout: Duration
    private let terminationGracePeriod: Duration

    public init(timeout: Duration = .seconds(5), terminationGracePeriod: Duration = .seconds(1)) {
        self.timeout = timeout
        self.terminationGracePeriod = terminationGracePeriod
    }

    public func run(executable: String, arguments: [String]) async throws -> CommandResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let processExit = CompletionSignal()
        let outcome = CompletionOutcome()
        process.terminationHandler = { _ in
            Task {
                await processExit.signal()
            }
        }

        try process.run()
        let stdoutTask = Task.detached {
            stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let stderrTask = Task.detached {
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let exitTask = Task {
            await processExit.wait()
            await outcome.resolve(exitedNormally: true)
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await outcome.resolve(exitedNormally: false)
        }

        let exitedNormally = await outcome.wait()
        timeoutTask.cancel()

        if !exitedNormally {
            process.terminate()
            let processIdentifier = process.processIdentifier
            let forceTerminationTask = Task {
                do {
                    try await Task.sleep(for: terminationGracePeriod)
                } catch {
                    return
                }

                if process.isRunning {
                    _ = Darwin.kill(processIdentifier, SIGKILL)
                }
            }
            await processExit.wait()
            forceTerminationTask.cancel()
        }

        exitTask.cancel()

        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: await stdoutTask.value, as: UTF8.self),
            stderr: String(decoding: await stderrTask.value, as: UTF8.self)
        )
    }
}

private actor CompletionSignal {
    private var didSignal = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    func signal() {
        guard !didSignal else { return }
        didSignal = true
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters {
            waiter.resume()
        }
    }

    func wait() async {
        guard !didSignal else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor CompletionOutcome {
    private var result: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?

    func resolve(exitedNormally: Bool) {
        guard result == nil else { return }
        result = exitedNormally
        waiter?.resume(returning: exitedNormally)
        waiter = nil
    }

    func wait() async -> Bool {
        if let result {
            return result
        }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }
}
