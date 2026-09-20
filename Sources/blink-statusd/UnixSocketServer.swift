import BlinkStatusCore
import Darwin
import Foundation

final class UnixSocketServer: @unchecked Sendable {
    typealias EventHandler = @Sendable (DaemonEvent) async -> Void

    static let maximumMessageSize = 16 * 1024
    static let receiveDeadlineNanoseconds: UInt64 = 200_000_000

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

        let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw UnixSocketServerError.systemCallFailed("socket")
        }

        var ownsSocketPath = false
        do {
            var address = try makeAddress()
            var result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fileDescriptor, $0, socketAddressLength())
                }
            }
            if result != 0, errno == EADDRINUSE {
                try removeStaleSocketIfNeeded()
                result = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(fileDescriptor, $0, socketAddressLength())
                    }
                }
            }
            guard result == 0 else {
                throw UnixSocketServerError.systemCallFailed("bind")
            }
            ownsSocketPath = true

            let permissionsResult = socketPath.withCString { Darwin.chmod($0, 0o600) }
            guard permissionsResult == 0 else {
                throw UnixSocketServerError.systemCallFailed("chmod")
            }

            guard Darwin.listen(fileDescriptor, SOMAXCONN) == 0 else {
                throw UnixSocketServerError.systemCallFailed("listen")
            }
        } catch {
            Darwin.close(fileDescriptor)
            if ownsSocketPath {
                socketPath.withCString { _ = Darwin.unlink($0) }
            }
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
            socketPath.withCString { _ = Darwin.unlink($0) }
        }
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

    private func removeStaleSocketIfNeeded() throws {
        var metadata = stat()
        let status = socketPath.withCString { Darwin.lstat($0, &metadata) }
        if status != 0 {
            guard errno == ENOENT else { throw UnixSocketServerError.systemCallFailed("lstat") }
            return
        }
        guard metadata.st_mode & S_IFMT == S_IFSOCK else {
            throw UnixSocketServerError.socketPathOccupied
        }

        let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw UnixSocketServerError.systemCallFailed("socket") }
        defer { Darwin.close(probe) }
        var address = try makeAddress()
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(probe, $0, socketAddressLength())
            }
        }
        if connected == 0 {
            throw UnixSocketServerError.alreadyRunning
        }
        let connectionError = errno
        guard connectionError == ECONNREFUSED || connectionError == ENOENT else {
            throw UnixSocketServerError.systemCallFailed("connect")
        }
        if connectionError == ECONNREFUSED {
            guard socketPath.withCString({ Darwin.unlink($0) }) == 0 else {
                throw UnixSocketServerError.systemCallFailed("unlink")
            }
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
        let deadline = DispatchTime.now().uptimeNanoseconds + receiveDeadlineNanoseconds

        while data.count < maximumMessageSize {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                return nil
            }
            let remainingMilliseconds = Int32(max(1, (deadline - now + 999_999) / 1_000_000))
            var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&descriptor, 1, remainingMilliseconds) > 0,
                  descriptor.revents & Int16(POLLIN) != 0 else {
                return nil
            }

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
    case socketPathOccupied
    case systemCallFailed(String)
}
