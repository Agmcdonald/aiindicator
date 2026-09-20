import Darwin
import Foundation
import XCTest
@testable import BlinkStatusCore
@testable import blink_statusd

final class UnixSocketServerTests: XCTestCase {
    func testServerDeliversPythonStyleUnixEpochEventAndSecuresSocket() async throws {
        let root = try temporaryDirectory()
        let socketDirectory = root.appendingPathComponent("blink-status")
        let socketPath = socketDirectory.appendingPathComponent("events.sock").path
        let recorder = EventRecorder()
        let server = UnixSocketServer(socketPath: socketPath) { event in
            await recorder.record(event)
        }
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: root)
        }
        try server.start()

        XCTAssertEqual(try permissions(of: socketDirectory.path), 0o700)
        XCTAssertEqual(try permissions(of: socketPath), 0o600)
        let client = try connect(to: socketPath)
        defer { Darwin.close(client) }
        try send(Data((#"{"action":"update","sourceID":"codex:session-123","applicationID":"com.openai.codex","state":1,"timestamp":1700000000,"expiresAt":1700007200}"# + "\n").utf8), to: client)

        let event = try await waitForEvent(from: recorder)
        XCTAssertEqual(event.sourceID, "codex:session-123")
        XCTAssertEqual(event.state, .working)
        XCTAssertEqual(event.timestamp, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(event.expiresAt, Date(timeIntervalSince1970: 1_700_007_200))
    }

    func testServerReceivesEventProducedByCodexHook() async throws {
        let root = try temporaryDirectory()
        let socketPath = root.appendingPathComponent("events.sock").path
        let recorder = EventRecorder()
        let server = UnixSocketServer(socketPath: socketPath) { event in
            await recorder.record(event)
        }
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: root)
        }
        try server.start()

        let hook = Process()
        hook.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        hook.arguments = [codexHookPath()]
        hook.environment = ProcessInfo.processInfo.environment.merging(
            ["BLINK_STATUS_SOCKET": socketPath],
            uniquingKeysWith: { _, new in new }
        )
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        hook.standardInput = input
        hook.standardOutput = output
        hook.standardError = errors
        try hook.run()
        input.fileHandleForWriting.write(Data(#"{"hook_event_name":"PermissionRequest","session_id":"session-123","turn_id":"turn-456"}"#.utf8))
        try input.fileHandleForWriting.close()
        hook.waitUntilExit()

        XCTAssertEqual(hook.terminationStatus, 0)
        XCTAssertTrue(try output.fileHandleForReading.readToEnd()?.isEmpty ?? true)
        XCTAssertTrue(try errors.fileHandleForReading.readToEnd()?.isEmpty ?? true)

        let event = try await waitForEvent(from: recorder)
        XCTAssertEqual(event.action, .update)
        XCTAssertEqual(event.sourceID, "codex:session-123")
        XCTAssertEqual(event.applicationID, "com.openai.codex-cli")
        XCTAssertEqual(event.state, .attention)
        guard let expiresAt = event.expiresAt else {
            return XCTFail("PermissionRequest should have an expiry")
        }
        XCTAssertEqual(expiresAt.timeIntervalSince(event.timestamp), 24 * 60 * 60, accuracy: 1)
    }

    func testServerRejectsOversizedAndMultilineFrames() async throws {
        let root = try temporaryDirectory()
        let socketPath = root.appendingPathComponent("events.sock").path
        let recorder = EventRecorder()
        let server = UnixSocketServer(socketPath: socketPath) { event in
            await recorder.record(event)
        }
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: root)
        }
        try server.start()

        let oversized = try connect(to: socketPath)
        try send(Data(repeating: 0x41, count: UnixSocketServer.maximumMessageSize + 1), to: oversized)
        Darwin.close(oversized)

        let multiline = try connect(to: socketPath)
        try send(Data((#"{"action":"update","sourceID":"codex:session-123","applicationID":"com.openai.codex","state":1,"timestamp":1700000000,"expiresAt":null}"# + "\n{}\n").utf8), to: multiline)
        Darwin.close(multiline)

        try await Task.sleep(for: .milliseconds(300))
        let eventCount = await recorder.count()
        XCTAssertEqual(eventCount, 0)
    }

    func testServerClosesIncompleteFramesAfterReceiveDeadline() async throws {
        let root = try temporaryDirectory()
        let socketPath = root.appendingPathComponent("events.sock").path
        let recorder = EventRecorder()
        let server = UnixSocketServer(socketPath: socketPath) { event in
            await recorder.record(event)
        }
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: root)
        }
        try server.start()

        let client = try connect(to: socketPath)
        defer { Darwin.close(client) }
        try send(Data("{\"action\":\"update\"".utf8), to: client)

        var descriptor = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
        let pollResult = Darwin.poll(&descriptor, 1, 1_000)
        XCTAssertEqual(pollResult, 1)
        guard pollResult == 1 else {
            return
        }
        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.recv(client, &byte, 1, 0), 0)
        let eventCount = await recorder.count()
        XCTAssertEqual(eventCount, 0)
    }

    func testSecondServerCannotReplaceLiveSocket() async throws {
        let root = try temporaryDirectory()
        let socketPath = root.appendingPathComponent("events.sock").path
        let firstRecorder = EventRecorder()
        let first = UnixSocketServer(socketPath: socketPath) { event in
            await firstRecorder.record(event)
        }
        let second = UnixSocketServer(socketPath: socketPath) { _ in }
        defer {
            second.stop()
            first.stop()
            try? FileManager.default.removeItem(at: root)
        }
        try first.start()

        XCTAssertThrowsError(try second.start()) { error in
            guard case UnixSocketServerError.alreadyRunning = error else {
                return XCTFail("Expected alreadyRunning, got \(error)")
            }
        }
        // Stopping or destroying a server that never acquired this path must
        // not unlink the first server's endpoint.
        second.stop()

        let client = try connect(to: socketPath)
        defer { Darwin.close(client) }
        let line = Data((#"{"action":"update","sourceID":"codex:session-123","applicationID":"com.openai.codex-cli","state":1,"timestamp":1700000000,"expiresAt":1700007200}"# + "\n").utf8)
        try send(line, to: client)
        let event = try await waitForEvent(from: firstRecorder)
        XCTAssertEqual(event.sourceID, "codex:session-123")
    }

    private func temporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("blink-status-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func codexHookPath() -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Scripts/codex_hook.py")
            .path
    }

    private func permissions(of path: String) throws -> mode_t {
        guard let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber else {
            throw POSIXError(.ENOENT)
        }
        return mode_t(permissions.intValue) & 0o777
    }

    private func connect(to path: String) throws -> Int32 {
        let client = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard client >= 0 else {
            throw POSIXError(.ENOTSOCK)
        }

        do {
            var address = try socketAddress(for: path)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(client, $0, socketAddressLength(for: path))
                }
            }
            guard result == 0 else {
                throw POSIXError(.ECONNREFUSED)
            }
            return client
        } catch {
            Darwin.close(client)
            throw error
        }
    }

    private func send(_ data: Data, to client: Int32) throws {
        let result = data.withUnsafeBytes { bytes in
            Darwin.send(client, bytes.baseAddress, bytes.count, 0)
        }
        guard result == data.count else {
            throw POSIXError(.EPIPE)
        }
    }

    private func socketAddress(for path: String) throws -> sockaddr_un {
        let pathBytes = Array(path.utf8)
        var address = sockaddr_un()
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            pathBytes.withUnsafeBytes { source in
                destination.baseAddress?.copyMemory(from: source.baseAddress!, byteCount: pathBytes.count)
            }
        }
        return address
    }

    private func socketAddressLength(for path: String) -> socklen_t {
        socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
    }

    private func waitForEvent(from recorder: EventRecorder) async throws -> DaemonEvent {
        for _ in 0..<100 {
            if let event = await recorder.first() {
                return event
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw EventWaitError.timedOut
    }
}

private enum EventWaitError: Error {
    case timedOut
}

private actor EventRecorder {
    private var events: [DaemonEvent] = []

    func record(_ event: DaemonEvent) {
        events.append(event)
    }

    func first() -> DaemonEvent? {
        events.first
    }

    func count() -> Int {
        events.count
    }
}
