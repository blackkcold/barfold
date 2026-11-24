import BarFoldProtocol
import Foundation

final class EventLog {
    private let url: URL
    private let queue = DispatchQueue(label: "com.haoran.BarFold.eventlog")
    private let maximumBytes: UInt64 = 1_048_576

    init(url: URL = BarFoldPaths.eventsURL) {
        self.url = url
    }

    func log(_ event: String, _ details: [String: JSONValue] = [:]) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let payload: JSONValue = .object([
            "timestamp": .string(timestamp),
            "event": .string(event),
            "details": .object(details),
        ])
        guard let data = try? JSONEncoder().encode(payload) else { return }
        var line = data
        line.append(0x0A)

        queue.async { [url, maximumBytes] in
            let fileManager = FileManager.default
            try? fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? UInt64, size > maximumBytes {
                let rotated = url.appendingPathExtension("1")
                try? fileManager.removeItem(at: rotated)
                try? fileManager.moveItem(at: url, to: rotated)
            }
            if !fileManager.fileExists(atPath: url.path) {
                fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        }
    }

    func tail(_ lineCount: Int) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return Array(lines.suffix(max(0, lineCount)))
    }
}
