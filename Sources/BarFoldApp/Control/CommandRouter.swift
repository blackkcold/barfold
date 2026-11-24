import AppKit
import BarFoldProtocol

@MainActor
final class CommandRouter {
    private let settings: SettingsStore
    private let statusItems: StatusItemController
    private let probe: ProbeService
    private let eventLog: EventLog
    private let capability: CapabilityReport
    private let startedAt: Date
    private let version: String
    private let testMode: Bool

    var onSetCollapsed: ((Bool, String) -> Void)?
    var onToggle: ((String) -> Void)?
    var onQuit: (() -> Void)?
    var onHotkeyChanged: (() -> Void)?
    var onHoverSimulate: ((Int) -> Void)?
    var onOpenSettings: (() -> Void)?
    var loginItemStatus: (() -> JSONValue)?
    var onLoginItemChange: ((Bool) -> Result<JSONValue, Error>)?
    var updateStatus: (() -> JSONValue)?
    var onUpdateCheck: (() -> JSONValue)?
    var onUpdateInstall: (() -> JSONValue)?

    init(
        settings: SettingsStore,
        statusItems: StatusItemController,
        probe: ProbeService,
        eventLog: EventLog,
        capability: CapabilityReport,
        startedAt: Date,
        version: String,
        testMode: Bool
    ) {
        self.settings = settings
        self.statusItems = statusItems
        self.probe = probe
        self.eventLog = eventLog
        self.capability = capability
        self.startedAt = startedAt
        self.version = version
        self.testMode = testMode
    }

    func handle(_ request: ControlRequest) -> ControlResponse {
        let start = Date()
        var response = route(request)
        response.durationMs = Date().timeIntervalSince(start) * 1000
        return response
    }

    /// Synchronous entry point for the in-app diagnostics UI.
    func selfTestData() -> JSONValue {
        selfTest(id: "ui", command: ControlCommand.selfTest).data ?? .null
    }

    private func route(_ request: ControlRequest) -> ControlResponse {
        let id = request.id
        let command = request.command

        switch command {
        case ControlCommand.ping:
            return success(id, command, .object([
                "pong": .bool(true),
                "protocol": .number(Double(ControlProtocol.version)),
                "pid": .number(Double(getpid())),
            ]))

        case ControlCommand.status:
            return success(id, command, probe.statusData())

        case ControlCommand.collapse:
            guard statusItems.engine.isAvailable else {
                return failure(id, command, ControlErrorCode.engineUnavailable, capability.detail)
            }
            onSetCollapsed?(true, "cli")
            return success(id, command, probe.statusData())

        case ControlCommand.expand:
            guard statusItems.engine.isAvailable else {
                return failure(id, command, ControlErrorCode.engineUnavailable, capability.detail)
            }
            onSetCollapsed?(false, "cli")
            return success(id, command, probe.statusData())

        case ControlCommand.toggle:
            guard statusItems.engine.isAvailable else {
                return failure(id, command, ControlErrorCode.engineUnavailable, capability.detail)
            }
            onToggle?("cli")
            return success(id, command, probe.statusData())

        case ControlCommand.probe:
            return success(id, command, probe.probeData())

        case ControlCommand.hoverSimulate:
            guard let onHoverSimulate else {
                return failure(id, command, ControlErrorCode.unsupported, "Hover simulation is unavailable")
            }
            let duration = max(0, min(5000, request.arguments?["durationMs"]?.intValue ?? 400))
            onHoverSimulate(duration)
            return success(id, command, probe.statusData())

        case ControlCommand.settingsGet:
            return success(id, command, settings.snapshot)

        case ControlCommand.settingsSet:
            guard let patch = settingsPatch(from: request.arguments) else {
                return failure(id, command, ControlErrorCode.invalidArgument, "settings.set needs a patch object")
            }
            do {
                let changed = try settings.apply(patch: patch)
                if changed.contains("hotkey") { onHotkeyChanged?() }
                return success(id, command, .object([
                    "changed": .array(changed.map { .string($0) }),
                    "settings": settings.snapshot,
                ]))
            } catch {
                return failure(id, command, ControlErrorCode.invalidArgument, error.localizedDescription)
            }

        case ControlCommand.hotkeyGet:
            return success(id, command, hotkeyData())

        case ControlCommand.hotkeySet:
            guard let arguments = request.arguments?.objectValue,
                  let value = arguments["hotkey"] else {
                return failure(id, command, ControlErrorCode.invalidArgument, "hotkey.set needs a hotkey value")
            }
            do {
                _ = try settings.apply(patch: .object(["hotkey": value]))
                onHotkeyChanged?()
                return success(id, command, hotkeyData())
            } catch {
                return failure(id, command, ControlErrorCode.invalidArgument, error.localizedDescription)
            }

        case ControlCommand.engineList:
            return success(id, command, .object([
                "current": .string(capability.kind.rawValue),
                "available": .array([
                    .object(["name": .string(EngineKind.lengthSpacer.rawValue), "available": .bool(true)]),
                    .object(["name": .string(EngineKind.unsupported.rawValue), "available": .bool(true)]),
                ]),
                "override": .string(settings.engineOverride),
                "detail": .string(capability.detail),
            ]))

        case ControlCommand.engineSelect:
            guard let engine = request.arguments?["engine"]?.stringValue,
                  ["auto", "lengthSpacer", "unsupported"].contains(engine) else {
                return failure(id, command, ControlErrorCode.invalidArgument, "engine.select needs auto, lengthSpacer, or unsupported")
            }
            do {
                _ = try settings.apply(patch: .object(["engineOverride": .string(engine)]))
                return success(id, command, .object([
                    "selected": .string(engine),
                    "restartRequired": .bool(true),
                    "detail": .string("The engine is selected at launch; restart BarFold to apply this override."),
                ]))
            } catch {
                return failure(id, command, ControlErrorCode.invalidArgument, error.localizedDescription)
            }

        case ControlCommand.doctor:
            return success(id, command, probe.doctorData())

        case ControlCommand.loginItemStatus:
            if let loginItemStatus {
                return success(id, command, loginItemStatus())
            }
            return success(id, command, .object([
                "enabled": .bool(false),
                "backend": .string("not_configured"),
                "detail": .string("Login item wiring lands in the settings milestone."),
            ]))

        case ControlCommand.loginItemEnable, ControlCommand.loginItemDisable:
            let enable = command == ControlCommand.loginItemEnable
            guard let onLoginItemChange else {
                return failure(id, command, ControlErrorCode.unsupported, "Login item wiring lands in the settings milestone.")
            }
            switch onLoginItemChange(enable) {
            case .success(let data):
                return success(id, command, data)
            case .failure(let error):
                return failure(id, command, ControlErrorCode.internalError, error.localizedDescription)
            }

        case ControlCommand.updateStatus:
            if let updateStatus {
                return success(id, command, updateStatus())
            }
            return success(id, command, .object([
                "configured": .bool(false),
                "reason": .string("Sparkle is not configured in this build."),
            ]))

        case ControlCommand.updateCheck:
            if let onUpdateCheck {
                return success(id, command, onUpdateCheck())
            }
            return failure(id, command, ControlErrorCode.unsupported, "Sparkle is not configured in this build.")

        case ControlCommand.updateInstall:
            if let onUpdateInstall {
                return success(id, command, onUpdateInstall())
            }
            return failure(id, command, ControlErrorCode.unsupported, "Sparkle is not configured in this build.")

        case ControlCommand.selfTest:
            return selfTest(id: id, command: command)

        case ControlCommand.logsTail:
            let lines = max(1, min(500, request.arguments?["lines"]?.intValue ?? 50))
            return success(id, command, .object([
                "path": .string(BarFoldPaths.eventsURL.path),
                "lines": .array(eventLog.tail(lines).map { .string($0) }),
            ]))

        case ControlCommand.appQuit:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.onQuit?()
            }
            return success(id, command, .object(["quitting": .bool(true)]))

        case ControlCommand.appSettings:
            onOpenSettings?()
            return success(id, command, .object(["opened": .bool(true)]))

        default:
            return failure(id, command, ControlErrorCode.usage, "Unknown command: \(command)")
        }
    }

    // MARK: - Helpers

    private func success(_ id: String, _ command: String, _ data: JSONValue? = nil) -> ControlResponse {
        .success(id: id, command: command, data: data)
    }

    private func failure(_ id: String, _ command: String, _ code: String, _ message: String) -> ControlResponse {
        .failure(id: id, command: command, code: code, message: message)
    }

    private func settingsPatch(from arguments: JSONValue?) -> JSONValue? {
        guard let object = arguments?.objectValue else { return nil }
        if let patch = object["patch"] { return patch }
        return .object(object)
    }

    private func hotkeyData() -> JSONValue {
        .object([
            "hotkey": settings.hotkey.map { .string($0.displayString) } ?? .null,
            "keyCode": settings.hotkey.map { .number(Double($0.keyCode)) } ?? .null,
            "modifiers": settings.hotkey.map { .number(Double($0.modifiers)) } ?? .null,
        ])
    }

    private func selfTest(id: String, command: String) -> ControlResponse {
        guard statusItems.engine.isAvailable else {
            return failure(id, command, ControlErrorCode.engineUnavailable, capability.detail)
        }

        let original = statusItems.isCollapsed
        var checks: [EngineCheck] = []

        onSetCollapsed?(true, "selftest")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        checks.append(contentsOf: statusItems.engine.verify().checks)
        checks.append(EngineCheck(
            name: "collapsed",
            status: statusItems.isCollapsed ? "pass" : "fail",
            detail: "expected collapsed=true, actual=\(statusItems.isCollapsed)"
        ))

        onSetCollapsed?(false, "selftest")
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        checks.append(EngineCheck(
            name: "expanded",
            status: !statusItems.isCollapsed ? "pass" : "fail",
            detail: "expected collapsed=false, actual=\(statusItems.isCollapsed)"
        ))

        if original {
            onSetCollapsed?(true, "selftest-restore")
        }

        let ok = !checks.contains { $0.status == "fail" }
        return success(id, command, .object([
            "ok": .bool(ok),
            "checks": .array(checks.map { check in
                .object([
                    "name": .string(check.name),
                    "status": .string(check.status),
                    "detail": .string(check.detail),
                ])
            }),
        ]))
    }
}
