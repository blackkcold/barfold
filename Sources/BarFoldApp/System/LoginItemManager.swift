import BarFoldProtocol
import Foundation
import ServiceManagement

struct LoginItemSnapshot: Equatable {
    var enabled: Bool
    var backend: String
    var detail: String
    var requiresApproval: Bool
    var bundlePath: String

    var json: JSONValue {
        .object([
            "enabled": .bool(enabled),
            "backend": .string(backend),
            "detail": .string(detail),
            "requiresApproval": .bool(requiresApproval),
            "bundlePath": .string(bundlePath),
        ])
    }

    static let disabled = LoginItemSnapshot(
        enabled: false,
        backend: "disabled",
        detail: "未开启",
        requiresApproval: false,
        bundlePath: Bundle.main.bundleURL.path
    )
}

/// Prefers SMAppService, falls back to a per-user LaunchAgent when the ad-hoc
/// or development build cannot register with the system login-item store.
final class LoginItemManager {
    private let fileManager = FileManager.default

    var bundlePath: String { Bundle.main.bundleURL.path }

    func status() -> LoginItemSnapshot {
        let serviceStatus = SMAppService.mainApp.status
        if serviceStatus == .enabled {
            return LoginItemSnapshot(
                enabled: true,
                backend: "smAppService",
                detail: "由 macOS 登录项管理",
                requiresApproval: false,
                bundlePath: bundlePath
            )
        }
        if serviceStatus == .requiresApproval {
            return LoginItemSnapshot(
                enabled: true,
                backend: "smAppService",
                detail: "等待系统设置中允许",
                requiresApproval: true,
                bundlePath: bundlePath
            )
        }
        if fileManager.fileExists(atPath: BarFoldPaths.launchAgentURL.path), launchAgentLoaded() {
            return LoginItemSnapshot(
                enabled: true,
                backend: "launchAgent",
                detail: launchAgentDetail,
                requiresApproval: false,
                bundlePath: bundlePath
            )
        }
        return .disabled
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) throws -> LoginItemSnapshot {
        if enabled {
            let serviceStatus = SMAppService.mainApp.status
            if serviceStatus == .enabled || serviceStatus == .requiresApproval {
                return status()
            }
            do {
                try SMAppService.mainApp.register()
                return status()
            } catch {
                // Fall through: ad-hoc/dev bundles often cannot register.
            }
            try enableLaunchAgent()
            return status()
        }

        if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
            try? SMAppService.mainApp.unregister()
        }
        disableLaunchAgent()
        return status()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - LaunchAgent fallback

    private var launchAgentDetail: String {
        if !bundlePath.hasPrefix("/Applications/") {
            return "使用 LaunchAgent 兜底；当前 App 不在 /Applications，移动后需重新开启"
        }
        return "使用 LaunchAgent 兜底"
    }

    private func enableLaunchAgent() throws {
        let executable = Bundle.main.executableURL?.path
            ?? "\(bundlePath)/Contents/MacOS/BarFold"
        let plist: [String: Any] = [
            "Label": BarFoldPaths.bundleIdentifier,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        let directory = BarFoldPaths.launchAgentURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: BarFoldPaths.launchAgentURL, options: .atomic)
        _ = chmod(BarFoldPaths.launchAgentURL.path, 0o600)

        let result = runLaunchctl([
            "bootstrap", "gui/\(getuid())", BarFoldPaths.launchAgentURL.path,
        ])
        // 37 = already bootstrapped; the plist is still the desired state.
        if result != 0 && result != 37 && !launchAgentLoaded() {
            throw NSError(
                domain: "BarFold.LoginItem",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: "launchctl bootstrap failed with status \(result)"]
            )
        }
    }

    private func disableLaunchAgent() {
        guard fileManager.fileExists(atPath: BarFoldPaths.launchAgentURL.path) else { return }
        _ = runLaunchctl([
            "bootout", "gui/\(getuid())", BarFoldPaths.launchAgentURL.path,
        ])
        try? fileManager.removeItem(at: BarFoldPaths.launchAgentURL)
    }

    private func launchAgentLoaded() -> Bool {
        runLaunchctl([
            "print", "gui/\(getuid())/\(BarFoldPaths.bundleIdentifier)",
        ]) == 0
    }

    private func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
