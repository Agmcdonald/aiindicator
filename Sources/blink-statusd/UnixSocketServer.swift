import BlinkStatusCore
import Darwin
import Foundation

final class UnixSocketServer: @unchecked Sendable {
    typealias EventHandler = @Sendable (DaemonEvent) async -> Void

    static let maximumMessageSize = 16 * 1024

    static var defaultSocketPath: String {
        "/tmp/blink-status-\(getuid())/events.sock"
    }

    private let socketPath: String
    private let handler: EventHandler
    private let lock = NSLock()
    private var listenerFD: Int32 = -1

    init(socketPath: String = UnixSocketServer.defaultSocketPath, handler: @escaping EventHandler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    deinit {
        stop()
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }

        guard listenerFD == -1 else {
            throw UnixSocketServerError.alreadyRunning
        }

        try createSocketDirectory()
        socketPath.withCString { _ = Darwin.unlink($0) }

        let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw UnixSocketServerError.systemCallFailed("socket")
        }

        do {
            var address = try makeAddress()
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fileDescriptor, $0, socketAddressLength())
                }
            }
            guard result == 0 else {
                throw UnixSocketServerError.systemCallFailed("bind")
            }

            let permissionsResult = socketPath.withCString { Darwin.chmod($0, 0o600) }
            guard permissionsResult == 0 else {
                throw UnixSocketServerError.systemCallFailed("chmod")
            }

            guard Darwin.listen(fileDescriptor, SOMAXCONN) == 0 else {
                throw UnixSocketServerError.systemCallFailed("listen")
            }
        } catch {
            Darwin.close(fileDescriptor)
            socketPath.withCString { _ = Darwin.unlink($0) }
            throw error
        }

        listenerFD = fileDescriptor
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.acceptConnections()
        }
    }

    func stop() {
        lock.lock()
        let fileDescriptor = listenerFD
        listenerFD = -1
        lock.unlock()

        if fileDescriptor >= 0 {
            Darwin.close(fileDescriptor)
        }
        socketPath.withCString { _ = Darwin.unlink($0) }
    }

    private func acceptConnections() {
        while true {
            let fileDescriptor = activeListener()
            guard fileDescriptor >= 0 else {
                return
            }

            let clientFD = Darwin.accept(fileDescriptor, nil, nil)
            if clientFD < 0 {
                if errno == EINTR {
                    continue
                }
                return
            }

            let handler = handler
            Task.detached {
                defer { Darwin.close(clientFD) }
                guard let event = Self.readEvent(from: clientFD) else {
                    return
                }
                await handler(event)
            }
        }
    }

    private func activeListener() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return listenerFD
    }

    private func createSocketDirectory() throws {
        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let result = directory.path.withCString { Darwin.chmod($0, 0o700) }
        guard result == 0 else {
            throw UnixSocketServerError.systemCallFailed("chmod")
        }
    }

    private func makeAddress() throws -> sockaddr_un {
        let pathBytes = Array(socketPath.utf8)
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            throw UnixSocketServerError.pathTooLong
        }

        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            pathBytes.withUnsafeBytes { source in
                destination.baseAddress?.copyMemory(
                    from: source.baseAddress!,
                    byteCount: pathBytes.count
                )
            }
        }
        return address
    }

    private func socketAddressLength() -> socklen_t {
        socklen_t(MemoryLayout<sa_family_t>.size + socketPath.utf8.count + 1)
    }

    private static func readEvent(from fileDescriptor: Int32) -> DaemonEvent? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)

        while data.count < maximumMessageSize {
            let count = Darwin.recv(fileDescriptor, &buffer, buffer.count, 0)
            guard count > 0 else {
                return nil
            }
            data.append(buffer, count: Int(count))

            guard data.count <= maximumMessageSize else {
                return nil
            }
            guard let newline = data.firstIndex(of: 0x0A) else {
                continue
            }
            guard newline == data.index(before: data.endIndex) else {
                return nil
            }
            return try? DaemonEvent.decodeLine(data)
        }

        return nil
    }
}

enum UnixSocketServerError: Error {
    case alreadyRunning
    case pathTooLong
    case systemCallFailed(String)
}
