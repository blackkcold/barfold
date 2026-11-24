import Darwin
import Foundation

public enum BarFoldPaths {
    public static let bundleIdentifier = "com.haoran.BarFold"
    public static let applicationName = "BarFold"

    /// Test and development builds override this so they never touch the real
    /// queue, socket, or state file.
    public static var supportDirectory: URL {
        if let raw = ProcessInfo.processInfo.environment["BARFOLD_SUPPORT_DIR"],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(applicationName, isDirectory: true)
    }

    public static var socketURL: URL {
        supportDirectory.appendingPathComponent("control.sock")
    }

    public static var stateURL: URL {
        supportDirectory.appendingPathComponent("state.json")
    }

    public static var eventsURL: URL {
        supportDirectory.appendingPathComponent("events.ndjson")
    }

    public static var lockURL: URL {
        supportDirectory.appendingPathComponent("app.lock")
    }

    public static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(bundleIdentifier).plist")
    }

    /// `sun_path` is 104 bytes on macOS. The default path is short enough; an
    /// override that is not must fail loudly instead of producing a broken socket.
    public static func validateSocketPath(_ path: String) throws {
        let limit = 100
        if path.utf8.count >= limit {
            throw NSError(
                domain: "BarFoldPaths",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Socket path is too long (\(path.utf8.count) bytes, limit \(limit)): \(path)"]
            )
        }
    }

    public static func ensureSupportDirectory() throws {
        let url = supportDirectory
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(url.path, 0o700)
    }
}
