import Foundation
import IslandProtocol

/// One accepted shim/ctl connection. Lines in, lines out. All I/O runs on the
/// server's queue; callbacks are invoked on that queue and must trampoline to
/// the main actor themselves.
public final class SocketConnection: @unchecked Sendable, Hashable {
    let fd: Int32
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var buffer = Data()
    private var closed = false

    var onLine: ((Data) -> Void)?
    var onClosed: (() -> Void)?

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource = source
        source.setEventHandler { [weak self] in
            self?.readAvailable()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            Darwin.close(self.fd)
        }
        source.resume()
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let n = read(fd, &chunk, chunk.count)
        if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
        if n <= 0 {
            finish()
            return
        }
        buffer.append(contentsOf: chunk[0..<n])
        if buffer.count > wireMaxLineBytes {
            finish()
            return
        }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { onLine?(line) }
        }
    }

    public func sendLine(_ data: Data) {
        queue.async { [self] in
            guard !closed else { return }
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    guard n > 0 else { return }
                    offset += n
                }
            }
        }
    }

    public func close() {
        queue.async { self.finish() }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        readSource?.cancel()
        readSource = nil
        onClosed?()
    }

    public static func == (lhs: SocketConnection, rhs: SocketConnection) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// NDJSON server on a Unix domain socket. The app owns exactly one of these.
public final class SocketServer: @unchecked Sendable {
    public static var defaultSocketPath: String {
        supportDirectory.appendingPathComponent("island.sock").path
    }

    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("aisland", isDirectory: true)
    }

    private let path: String
    private let queue = DispatchQueue(label: "com.aisland.socket")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: Set<SocketConnection> = []

    /// Called on the socket queue with each complete line.
    public var onLine: (@Sendable (Data, SocketConnection) -> Void)?

    public init(path: String = SocketServer.defaultSocketPath) {
        self.path = path
    }

    public func start() throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        listenFD = fd
        // Non-blocking: the accept loop must drain and return, never park the
        // shared socket queue inside a blocking accept().
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            pathBytes.withUnsafeBytes { src in dest.copyBytes(from: src) }
        }
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        acceptSource = source
        source.setEventHandler { [weak self] in
            self?.acceptPending()
        }
        source.resume()
    }

    private func acceptPending() {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else { return }
            _ = fcntl(clientFD, F_SETFL, fcntl(clientFD, F_GETFL) | O_NONBLOCK)
            let connection = SocketConnection(fd: clientFD, queue: queue)
            connections.insert(connection)
            connection.onLine = { [weak self, weak connection] line in
                guard let self, let connection else { return }
                self.onLine?(line, connection)
            }
            connection.onClosed = { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.connections.remove(connection)
            }
            connection.start()
        }
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        connections.forEach { $0.close() }
        connections.removeAll()
        unlink(path)
    }
}
