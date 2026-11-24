import BarFoldProtocol
import Darwin
import Foundation

/// A local-only JSON-lines server on a Unix domain socket. It is the app's
/// first-class automation surface: deterministic state and actions, no GUI.
final class ControlServer {
    typealias Handler = (ControlRequest) -> ControlResponse

    private let socketURL: URL
    private let handler: Handler
    private let acceptQueue = DispatchQueue(label: "com.haoran.BarFold.control.accept")
    private let workerQueue = DispatchQueue(
        label: "com.haoran.BarFold.control.worker",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private var listenDescriptor: Int32 = -1
    private var source: DispatchSourceRead?

    private let localPeerCred: Int32 = 0x001
    private let localSocketLevel: Int32 = 0

    init(socketURL: URL = BarFoldPaths.socketURL, handler: @escaping Handler) {
        self.socketURL = socketURL
        self.handler = handler
    }

    deinit {
        stop()
    }

    func start() throws {
        try BarFoldPaths.ensureSupportDirectory()
        try BarFoldPaths.validateSocketPath(socketURL.path)
        signal(SIGPIPE, SIG_IGN)
        removeStaleSocket()

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw posixError("socket")
        }

        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketURL.path.utf8CString)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= pathCapacity else {
            close(descriptor)
            throw NSError(
                domain: "BarFold.ControlServer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Socket path does not fit sun_path"]
            )
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { destination in
                for index in 0..<pathCapacity { destination[index] = 0 }
                for (index, byte) in pathBytes.enumerated() { destination[index] = byte }
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            close(descriptor)
            throw posixError("bind", code)
        }

        _ = chmod(socketURL.path, 0o600)

        guard listen(descriptor, 16) == 0 else {
            let code = errno
            close(descriptor)
            throw posixError("listen", code)
        }

        listenDescriptor = descriptor
        let readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: acceptQueue)
        readSource.setEventHandler { [weak self] in
            self?.acceptPendingConnections()
        }
        readSource.setCancelHandler {
            close(descriptor)
        }
        readSource.resume()
        source = readSource
    }

    func stop() {
        source?.cancel()
        source = nil
        listenDescriptor = -1
        unlink(socketURL.path)
    }

    private func removeStaleSocket() {
        var info = stat()
        guard lstat(socketURL.path, &info) == 0 else { return }
        if (info.st_mode & S_IFMT) == S_IFSOCK {
            unlink(socketURL.path)
        }
    }

    private func acceptPendingConnections() {
        while true {
            var address = sockaddr_un()
            var length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let client = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    accept(listenDescriptor, sockaddrPointer, &length)
                }
            }
            if client < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                break
            }
            configure(client)
            workerQueue.async { [weak self] in
                self?.serve(client)
            }
        }
    }

    private func configure(_ descriptor: Int32) {
        // Accepted sockets can inherit O_NONBLOCK from the listening socket on
        // macOS; clear it before installing the receive timeout.
        let flags = fcntl(descriptor, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK)
        }
        var timeout = timeval(tv_sec: Int(ControlProtocol.connectionTimeout), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private func serve(_ descriptor: Int32) {
        defer { close(descriptor) }

        guard peerUID(descriptor) == getuid() else {
            return
        }

        guard let requestData = readRequest(descriptor) else {
            write(
                ControlResponse.failure(
                    id: "unknown",
                    command: "unknown",
                    code: ControlErrorCode.invalidArgument,
                    message: "Empty request"
                ),
                to: descriptor
            )
            return
        }

        let request: ControlRequest
        do {
            request = try JSONDecoder().decode(ControlRequest.self, from: requestData)
        } catch {
            NSLog("BarFold control: decode failed: %@ raw=%@",
                  String(describing: error),
                  String(data: requestData, encoding: .utf8) ?? "<non-utf8>")
            write(
                ControlResponse.failure(
                    id: "unknown",
                    command: "unknown",
                    code: ControlErrorCode.invalidArgument,
                    message: "Malformed request"
                ),
                to: descriptor
            )
            return
        }

        let response: ControlResponse
        if Thread.isMainThread {
            response = handler(request)
        } else {
            var boxed: ControlResponse?
            DispatchQueue.main.sync {
                boxed = self.handler(request)
            }
            response = boxed ?? .failure(
                id: request.id,
                command: request.command,
                code: ControlErrorCode.internalError,
                message: "Main thread did not produce a response"
            )
        }
        write(response, to: descriptor)
    }

    private func peerUID(_ descriptor: Int32) -> uid_t? {
        var credentials = xucred()
        var length = socklen_t(MemoryLayout<xucred>.size)
        let result = getsockopt(
            descriptor,
            localSocketLevel,
            localPeerCred,
            &credentials,
            &length
        )
        guard result == 0 else { return nil }
        return credentials.cr_uid
    }

    private func readRequest(_ descriptor: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(ControlProtocol.connectionTimeout)
        while data.count <= ControlProtocol.maxMessageBytes {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return 0 }
                return read(descriptor, base, rawBuffer.count)
            }
            if count > 0 {
                data.append(contentsOf: buffer[0..<count])
                if data.contains(0x0A) { break }
                continue
            }
            if count == 0 { break }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                if Date() >= deadline { break }
                usleep(10_000)
                continue
            }
            break
        }
        if let newline = data.firstIndex(of: 0x0A) {
            data = Data(data[..<newline])
        }
        return data.isEmpty ? nil : data
    }

    private func write(_ response: ControlResponse, to descriptor: Int32) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if count <= 0 { break }
                offset += count
            }
        }
    }

    private func posixError(_ operation: String, _ code: Int32 = errno) -> NSError {
        let message = String(cString: strerror(code))
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(message) (\(code))"]
        )
    }
}
