import Foundation

public enum ControlProtocol {
    public static let version = 1
    public static let clientName = "barfoldctl/1.0"
    public static let maxMessageBytes = 1_048_576
    public static let connectionTimeout: TimeInterval = 5
}

public enum ControlErrorCode {
    public static let usage = "usage"
    public static let appUnavailable = "app_unavailable"
    public static let engineUnavailable = "engine_unavailable"
    public static let invalidArgument = "invalid_argument"
    public static let refused = "refused"
    public static let internalError = "internal_error"
    public static let timeout = "timeout"
    public static let conflict = "conflict"
    public static let unsupported = "unsupported"
}

public enum ControlExitCode: Int32, Sendable {
    case ok = 0
    case usage = 2
    case appUnavailable = 3
    case appError = 4
    case timeout = 5
}

public struct ControlRequest: Codable, Sendable {
    public var id: String
    public var command: String
    public var arguments: JSONValue?

    public init(
        id: String = UUID().uuidString,
        command: String,
        arguments: JSONValue? = nil
    ) {
        self.id = id
        self.command = command
        self.arguments = arguments
    }
}

public struct ControlError: Codable, Sendable, Equatable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct ControlResponse: Codable, Sendable {
    public var id: String
    public var ok: Bool
    public var command: String
    public var data: JSONValue?
    public var error: ControlError?
    public var durationMs: Double?

    public init(
        id: String,
        ok: Bool,
        command: String,
        data: JSONValue? = nil,
        error: ControlError? = nil,
        durationMs: Double? = nil
    ) {
        self.id = id
        self.ok = ok
        self.command = command
        self.data = data
        self.error = error
        self.durationMs = durationMs
    }

    public static func success(
        id: String,
        command: String,
        data: JSONValue? = nil,
        durationMs: Double? = nil
    ) -> ControlResponse {
        ControlResponse(id: id, ok: true, command: command, data: data, durationMs: durationMs)
    }

    public static func failure(
        id: String,
        command: String,
        code: String,
        message: String,
        durationMs: Double? = nil
    ) -> ControlResponse {
        ControlResponse(
            id: id,
            ok: false,
            command: command,
            error: ControlError(code: code, message: message),
            durationMs: durationMs
        )
    }
}

public enum ControlCommand {
    public static let ping = "ping"
    public static let status = "status"
    public static let collapse = "collapse"
    public static let expand = "expand"
    public static let toggle = "toggle"
    public static let probe = "probe"
    public static let hoverSimulate = "hover.simulate"
    public static let settingsGet = "settings.get"
    public static let settingsSet = "settings.set"
    public static let hotkeyGet = "hotkey.get"
    public static let hotkeySet = "hotkey.set"
    public static let engineList = "engine.list"
    public static let engineSelect = "engine.select"
    public static let doctor = "doctor"
    public static let loginItemStatus = "loginitem.status"
    public static let loginItemEnable = "loginitem.enable"
    public static let loginItemDisable = "loginitem.disable"
    public static let updateStatus = "update.status"
    public static let updateCheck = "update.check"
    public static let updateInstall = "update.install"
    public static let selfTest = "selftest"
    public static let logsTail = "logs.tail"
    public static let appQuit = "app.quit"
    public static let appSettings = "app.settings"

    public static let all: Set<String> = [
        ping, status, collapse, expand, toggle, probe, hoverSimulate,
        settingsGet, settingsSet, hotkeyGet, hotkeySet,
        engineList, engineSelect, doctor,
        loginItemStatus, loginItemEnable, loginItemDisable,
        updateStatus, updateCheck, updateInstall,
        selfTest, logsTail, appQuit, appSettings,
    ]
}
