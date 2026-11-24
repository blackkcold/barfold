import AppKit
import BarFoldProtocol

@MainActor
final class ProbeService {
    private let statusItems: StatusItemController
    private let settings: SettingsStore
    private let capability: CapabilityReport
    private let startedAt: Date
    private let testMode: Bool

    var safeMode: () -> Bool = { false }
    var version: () -> String = { "0.1.0" }
    var socketPath: String = BarFoldPaths.socketURL.path
    var hotkeyError: () -> String? = { nil }
    var loginItemStatus: () -> JSONValue? = { nil }
    var updateStatus: () -> JSONValue? = { nil }

    init(
        statusItems: StatusItemController,
        settings: SettingsStore,
        capability: CapabilityReport,
        startedAt: Date,
        testMode: Bool
    ) {
        self.statusItems = statusItems
        self.settings = settings
        self.capability = capability
        self.startedAt = startedAt
        self.testMode = testMode
    }

    func statusData() -> JSONValue {
        var data = statusItems.snapshotData()
        data["pid"] = .number(Double(getpid()))
        data["running"] = .bool(true)
        data["version"] = .string(version())
        data["uptimeSeconds"] = .number(Date().timeIntervalSince(startedAt))
        data["settings"] = settings.snapshot
        data["screens"] = .array(ScreenMapping.descriptors.map(Self.screenJSON))
        data["systemThickness"] = .number(ScreenMapping.systemThickness)
        data["menuBarBands"] = .array(ScreenMapping.descriptors.map { screen in
            let band = MenuBarGeometry.menuBarBand(for: screen, systemThickness: ScreenMapping.systemThickness)
            return Self.rectJSON(band)
        })
        data["toggleOnScreen"] = .bool(toggleOnScreen)
        data["statusWindowCount"] = .number(Double(MenuBarProbe.statusWindows().count))
        data["visibleStatusWindowCount"] = .number(Double(MenuBarProbe.visibleStatusWindowCount()))
        data["menuOpen"] = .bool(MenuBarProbe.hasOpenMenu())
        data["otherManagers"] = MenuBarProbe.runningManagerSummary()
        data["safeMode"] = .bool(safeMode())
        data["socketPath"] = .string(socketPath)
        data["hotkeyError"] = .string(hotkeyError() ?? "")

        // A state bool flips immediately, but the window server needs a run-loop
        // turn to move the icons. `wait` must observe the geometry, not the bool.
        let separatorWidth = statusItems.separatorFrame?.width ?? 0
        // Expanded no longer means "a narrow separator window": the separator is
        // hidden outright, so the honest signal is its absence plus a live arrow.
        let toggleX = statusItems.toggleFrame?.origin.x ?? 0
        var settled = statusItems.isCollapsed
            ? separatorWidth > 1000
            : (separatorWidth > 0 && statusItems.toggleFrame != nil && toggleX > 0)
        if statusItems.canaryItem != nil {
            let canaryVisible = statusItems.canaryOnScreen
            settled = settled && (statusItems.isCollapsed ? !canaryVisible : canaryVisible)
        }
        data["layoutSettled"] = .bool(settled)
        data["separatorWindowWidth"] = .number(Double(separatorWidth))
        return .object(data)
    }

    func probeData() -> JSONValue {
        let status = statusData()
        var data = status.objectValue ?? [:]
        data["statusWindows"] = .array(MenuBarProbe.statusWindows().map(Self.statusWindowJSON))
        data["engineVerification"] = verificationJSON(statusItems.engine.verify())
        data["expandedLength"] = .number(MenuBarGeometry.expandedLength)
        data["collapsedLengthRequested"] = .number(
            MenuBarGeometry.collapsedLength(for: ScreenMapping.descriptors)
        )
        data["toggleFrame"] = statusItems.toggleFrame.map(Self.frameJSON) ?? .null
        data["separatorFrame"] = statusItems.separatorFrame.map(Self.frameJSON) ?? .null
        if let frame = statusItems.canaryFrame {
            data["canaryFrame"] = Self.frameJSON(frame)
            data["canaryOnScreen"] = .bool(statusItems.canaryOnScreen)
        }
        return .object(data)
    }

    func doctorData() -> JSONValue {
        var checks: [JSONValue] = []

        func add(_ name: String, _ status: String, _ detail: String) {
            checks.append(.object([
                "name": .string(name),
                "status": .string(status),
                "detail": .string(detail),
            ]))
        }

        add("app-running", "pass", "pid \(getpid()), uptime \(Int(Date().timeIntervalSince(startedAt)))s")
        add("engine", statusItems.engine.isAvailable ? "pass" : "fail", capability.detail)

        if let frame = statusItems.toggleFrame {
            let onScreen = MenuBarGeometry.isOnAnyScreen(
                Rect(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height),
                screens: ScreenMapping.descriptors
            )
            add("arrow-on-screen", onScreen ? "pass" : "warn",
                "frame=\(NSStringFromRect(frame))")
        } else {
            add("arrow-on-screen", "fail", "arrow window is missing")
        }

        if let frame = statusItems.separatorFrame {
            let wideEnough = frame.width > 1000 || !statusItems.isCollapsed
            add("separator", wideEnough ? "pass" : "fail",
                "length=\(Int(statusItems.separatorLength)), window-width=\(Int(frame.width))")
        } else if capability.kind == .lengthSpacer {
            add("separator", "fail", "separator window is missing")
        } else {
            add("separator", "warn", "not used by this engine")
        }

        let managers = MenuBarProbe.otherManagerNames()
        add("other-managers", managers.isEmpty ? "pass" : "warn",
            managers.isEmpty ? "none detected" : "running: \(managers.joined(separator: ", "))")

        if let login = loginItemStatus() {
            let enabled = login["enabled"]?.boolValue ?? false
            add("login-item", enabled ? "pass" : "warn", login["detail"]?.stringValue ?? "")
        }

        if let update = updateStatus() {
            let configured = update["configured"]?.boolValue ?? false
            add("update", configured ? "pass" : "warn",
                configured
                    ? "Sparkle configured"
                    : "Sparkle not configured: fixed signature and EdDSA key required")
        }

        if let hotkeyErrorValue = hotkeyError(), !hotkeyErrorValue.isEmpty {
            add("hotkey", "warn", hotkeyErrorValue)
        } else {
            add("hotkey", "pass", settings.hotkey?.displayString ?? "none")
        }

        let screens = ScreenMapping.descriptors
        add("screens", "pass",
            "\(screens.count) screen(s), widest \(Int(MenuBarGeometry.widestScreenWidth(screens)))pt")

        let socketMode = socketPermissions()
        add("socket", FileManager.default.fileExists(atPath: socketPath) ? "pass" : "warn",
            "path=\(socketPath), mode=\(socketMode)")

        add("accessibility", "pass", "no Accessibility, Screen Recording or Input Monitoring permission requested")
        add("notifications", "pass", "no notification permission requested")

        return .object([
            "ok": .bool(!checks.contains { check in
                check["status"]?.stringValue == "fail"
            }),
            "checks": .array(checks),
            "generatedAt": .string(ISO8601DateFormatter().string(from: Date())),
        ])
    }

    func verificationJSON(_ verification: EngineVerification) -> JSONValue {
        .object([
            "ok": .bool(verification.ok),
            "checks": .array(verification.checks.map { check in
                .object([
                    "name": .string(check.name),
                    "status": .string(check.status),
                    "detail": .string(check.detail),
                ])
            }),
        ])
    }

    var toggleOnScreen: Bool {
        guard let frame = statusItems.toggleFrame else { return false }
        return MenuBarGeometry.isOnAnyScreen(
            Rect(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height),
            screens: ScreenMapping.descriptors
        )
    }

    private func socketPermissions() -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: socketPath),
              let mode = attributes[.posixPermissions] as? NSNumber else {
            return "missing"
        }
        return String(format: "0o%03o", mode.intValue & 0o777)
    }

    private static func screenJSON(_ screen: ScreenDescriptor) -> JSONValue {
        .object([
            "name": .string(screen.name),
            "frame": rectJSON(screen.frame),
            "visibleFrame": rectJSON(screen.visibleFrame),
            "safeAreaTop": .number(screen.safeAreaTop),
            "isMain": .bool(screen.isMain),
            "backingScale": .number(screen.backingScale),
            "menuBarHeight": .number(MenuBarGeometry.menuBarHeight(
                for: screen,
                systemThickness: ScreenMapping.systemThickness
            )),
        ])
    }

    private static func statusWindowJSON(_ record: StatusWindowRecord) -> JSONValue {
        .object([
            "owner": .string(record.ownerName),
            "pid": .number(Double(record.ownerPID)),
            "window": .number(Double(record.windowNumber)),
            "layer": .number(Double(record.layer)),
            "onscreen": .bool(record.isOnscreen),
            "frame": rectJSON(record.frame),
        ])
    }

    private static func frameJSON(_ frame: NSRect) -> JSONValue {
        .object([
            "x": .number(Double(frame.origin.x)),
            "y": .number(Double(frame.origin.y)),
            "width": .number(Double(frame.width)),
            "height": .number(Double(frame.height)),
        ])
    }

    static func rectJSON(_ rect: Rect) -> JSONValue {
        .object([
            "x": .number(rect.x),
            "y": .number(rect.y),
            "width": .number(rect.width),
            "height": .number(rect.height),
        ])
    }
}
