import BarFoldProtocol
import Darwin
import Foundation

enum ControlClientError: LocalizedError {
    case appUnavailable
    case io(String)
    case decode(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .appUnavailable:
            return "BarFold is not running"
        case .io(let message):
            return message
        case .decode(let message):
            return "Could not decode the app response: \(message)"
        case .timeout:
            return "The app did not answer before the timeout"
        }
    }
}

struct ControlClient {
    let socketPath: String
    let timeout: TimeInterval

    init(socketPath: String = BarFoldPaths.socketURL.path, timeout: TimeInterval = 3) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    func send(_ request: ControlRequest) throws -> ControlResponse {
        signal(SIGPIPE, SIG_IGN)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ControlClientError.io("socket() failed: \(posixMessage())")
        }
        defer { close(descriptor) }

        var timevalValue = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000)
        )
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timevalValue, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timevalValue, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else {
            throw ControlClientError.io("socket path is too long")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for index in 0..<capacity { destination[index] = 0 }
                for (index, byte) in pathBytes.enumerated() { destination[index] = byte }
            }
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            let code = errno
            if code == ENOENT || code == ECONNREFUSED || code == ECONNRESET {
                throw ControlClientError.appUnavailable
            }
            throw ControlClientError.io("connect() failed: \(posixMessage(code))")
        }

        guard var data = try? JSONEncoder().encode(request) else {
            throw ControlClientError.io("Could not encode the request")
        }
        data.append(0x0A)
        try writeAll(descriptor, data)
        let responseData = try readResponse(descriptor)
        do {
            return try JSONDecoder().decode(ControlResponse.self, from: responseData)
        } catch {
            throw ControlClientError.decode(error.localizedDescription)
        }
    }

    private func writeAll(_ descriptor: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
                if count <= 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        throw ControlClientError.timeout
                    }
                    throw ControlClientError.io("write() failed: \(posixMessage())")
                }
                offset += count
            }
        }
    }

    private func readResponse(_ descriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
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
                throw ControlClientError.timeout
            }
            throw ControlClientError.io("read() failed: \(posixMessage())")
        }
        if let newline = data.firstIndex(of: 0x0A) {
            data = Data(data[..<newline])
        }
        guard !data.isEmpty else {
            throw ControlClientError.appUnavailable
        }
        return data
    }

    private func posixMessage(_ code: Int32 = errno) -> String {
        String(cString: strerror(code))
    }
}
