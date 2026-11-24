import BarFoldProtocol
import Darwin
import Foundation

struct CLI {
    private let arguments: [String]
    private var jsonOutput = false
    private var humanOutput = false
    private var noColor = false
    private var timeout: TimeInterval = 3
    private var command: String?
    private var rest: [String] = []

    init(arguments: [String]) {
        self.arguments = arguments
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--json":
                jsonOutput = true
            case "--human":
                humanOutput = true
            case "--no-color":
                noColor = true
            case "--timeout":
                if index + 1 < arguments.count, let milliseconds = Double(arguments[index + 1]) {
                    timeout = max(0.1, milliseconds / 1000)
                    index += 1
                }
            case "--version", "-v":
                command = "version"
            case "--help", "-h":
                command = "help"
            default:
                if command == nil {
                    command = argument
                } else {
                    rest.append(argument)
                }
            }
            index += 1
        }
        if !jsonOutput && !humanOutput {
            jsonOutput = isatty(STDOUT_FILENO) == 0
        }
    }

    func run() -> Int32 {
        switch command {
        case nil, "help":
            printHelp()
            return 0
        case "version":
            print("barfold 0.1.0")
            return 0
        case "launch":
            return launchCommand()
        case "wait":
            return waitCommand()
        case "doctor":
            return checkCommand(command: ControlCommand.doctor, render: renderDoctor)
        case "selftest":
            return checkCommand(command: ControlCommand.selfTest, render: renderDoctor)
        case "probe":
            return simpleCommand(ControlCommand.probe, render: renderProbe)
        case "status":
            return simpleCommand(ControlCommand.status, render: renderStatus)
        case "ping":
            return simpleCommand(ControlCommand.ping, render: nil)
        case "collapse":
            return simpleCommand(ControlCommand.collapse, render: renderStatus)
        case "expand":
            return simpleCommand(ControlCommand.expand, render: renderStatus)
        case "toggle":
            return simpleCommand(ControlCommand.toggle, render: renderStatus)
        case "settings":
            return settingsCommand()
        case "hotkey":
            return hotkeyCommand()
        case "engine":
            return engineCommand()
        case "logs":
            return logsCommand()
        case "hover":
            return hoverCommand()
        case "loginitem":
            return subcommandCommand(
                name: "loginitem",
                mapping: [
                    "status": ControlCommand.loginItemStatus,
                    "enable": ControlCommand.loginItemEnable,
                    "disable": ControlCommand.loginItemDisable,
                ]
            )
        case "update":
            return subcommandCommand(
                name: "update",
                mapping: [
                    "status": ControlCommand.updateStatus,
                    "check": ControlCommand.updateCheck,
                    "install": ControlCommand.updateInstall,
                ]
            )
        case "quit":
            return simpleCommand(ControlCommand.appQuit, render: nil)
        default:
            return usageError("unknown command: \(command ?? "")")
        }
    }

    // MARK: - Commands

    private func simpleCommand(_ command: String, render: ((JSONValue) -> Void)?) -> Int32 {
        let request = ControlRequest(command: command)
        return perform(request, render: render)
    }

    private func subcommandCommand(name: String, mapping: [String: String]) -> Int32 {
        guard let subcommand = rest.first, let command = mapping[subcommand] else {
            return usageError("\(name) needs one of: \(mapping.keys.sorted().joined(separator: ", "))")
        }
        return simpleCommand(command, render: nil)
    }

    private func checkCommand(command: String, render: (JSONValue) -> Void) -> Int32 {
        let request = ControlRequest(command: command)
        do {
            let response = try client().send(request)
            guard response.ok else {
                printError(code: response.error?.code ?? "internal_error",
                           message: response.error?.message ?? "unknown error")
                return exitCode(for: response.error?.code)
            }
            let data = response.data ?? .null
            if jsonOutput { printData(data) } else { render(data) }
            return data["ok"]?.boolValue == false ? 4 : 0
        } catch {
            printError(code: "app_unavailable", message: error.localizedDescription)
            return 3
        }
    }

    private func waitCommand() -> Int32 {
        guard let wanted = rest.first else {
            return usageError("wait needs collapsed or expanded")
        }
        let wantedCollapsed: Bool
        switch wanted.lowercased() {
        case "collapsed", "collapse", "true", "1": wantedCollapsed = true
        case "expanded", "expand", "false", "0": wantedCollapsed = false
        default: return usageError("wait needs collapsed or expanded")
        }

        let deadline = Date().addingTimeInterval(timeout)
        let started = Date()
        while Date() < deadline {
            do {
                let response = try client().send(ControlRequest(command: ControlCommand.status))
                guard response.ok, let data = response.data,
                      let collapsed = data["collapsed"]?.boolValue else {
                    printError(code: response.error?.code ?? "internal_error",
                               message: response.error?.message ?? "status did not include collapsed")
                    return exitCode(for: response.error?.code)
                }
                if collapsed == wantedCollapsed,
                   data["layoutSettled"]?.boolValue == true {
                    if jsonOutput {
                        printData(data)
                    } else {
                        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                        print("\(wantedCollapsed ? "已收起" : "已展开") (\(elapsed)ms)")
                    }
                    return 0
                }
            } catch {
                printError(code: "app_unavailable", message: error.localizedDescription)
                return 3
            }
            usleep(100_000)
        }

        printError(code: "timeout", message: "did not reach \(wantedCollapsed ? "collapsed" : "expanded") within \(Int(timeout * 1000))ms")
        return 5
    }

    private func settingsCommand() -> Int32 {
        guard let subcommand = rest.first else {
            return usageError("settings needs get or set")
        }
        switch subcommand {
        case "get":
            return perform(ControlRequest(command: ControlCommand.settingsGet), render: renderSettings)
        case "open":
            return simpleCommand(ControlCommand.appSettings, render: nil)
        case "set":
            let pairs = rest.dropFirst()
            guard !pairs.isEmpty else {
                return usageError("settings set needs key=value pairs")
            }
            var patch: [String: JSONValue] = [:]
            for pair in pairs {
                guard let separator = pair.firstIndex(of: "=") else {
                    return usageError("expected key=value, got '\(pair)'")
                }
                let key = String(pair[..<separator])
                let rawValue = String(pair[pair.index(after: separator)...])
                if key == "hotkey" {
                    if rawValue.isEmpty || rawValue.lowercased() == "none" {
                        patch[key] = .null
                    } else if let combo = KeyCombo.parse(rawValue) {
                        patch[key] = .object([
                            "keyCode": .number(Double(combo.keyCode)),
                            "modifiers": .number(Double(combo.modifiers)),
                        ])
                    } else {
                        return usageError("invalid hotkey '\(rawValue)'")
                    }
                    continue
                }
                if rawValue.lowercased() == "true" {
                    patch[key] = .bool(true)
                } else if rawValue.lowercased() == "false" {
                    patch[key] = .bool(false)
                } else if let number = Double(rawValue) {
                    patch[key] = .number(number)
                } else {
                    patch[key] = .string(rawValue)
                }
            }
            let request = ControlRequest(
                command: ControlCommand.settingsSet,
                arguments: .object(["patch": .object(patch)])
            )
            return perform(request, render: { data in
                self.renderSettings(data["settings"] ?? data)
            })
        default:
            return usageError("settings needs get or set")
        }
    }

    private func hotkeyCommand() -> Int32 {
        guard let subcommand = rest.first else {
            return usageError("hotkey needs get, set, or clear")
        }
        switch subcommand {
        case "get":
            return perform(ControlRequest(command: ControlCommand.hotkeyGet), render: renderHotkey)
        case "set":
            let raw = rest.dropFirst().joined(separator: " ")
            guard let combo = KeyCombo.parse(raw) else {
                return usageError("invalid hotkey '\(raw)'")
            }
            let request = ControlRequest(
                command: ControlCommand.hotkeySet,
                arguments: .object([
                    "hotkey": .object([
                        "keyCode": .number(Double(combo.keyCode)),
                        "modifiers": .number(Double(combo.modifiers)),
                    ]),
                ])
            )
            return perform(request, render: renderHotkey)
        case "clear":
            let request = ControlRequest(
                command: ControlCommand.hotkeySet,
                arguments: .object(["hotkey": .null])
            )
            return perform(request, render: renderHotkey)
        default:
            return usageError("hotkey needs get, set, or clear")
        }
    }

    private func engineCommand() -> Int32 {
        guard let subcommand = rest.first else {
            return usageError("engine needs list or select")
        }
        switch subcommand {
        case "list":
            return perform(ControlRequest(command: ControlCommand.engineList), render: renderEngine)
        case "select":
            guard let name = rest.dropFirst().first else {
                return usageError("engine select needs auto, lengthSpacer, or unsupported")
            }
            let request = ControlRequest(
                command: ControlCommand.engineSelect,
                arguments: .object(["engine": .string(name)])
            )
            return perform(request, render: nil)
        default:
            return usageError("engine needs list or select")
        }
    }

    private func hoverCommand() -> Int32 {
        guard rest.first == "simulate" else {
            return usageError("hover needs simulate")
        }
        var duration = 400
        if let index = rest.firstIndex(of: "--duration"),
           index + 1 < rest.count,
           let value = Int(rest[index + 1]) {
            duration = max(0, min(5000, value))
        }
        let request = ControlRequest(
            command: ControlCommand.hoverSimulate,
            arguments: .object(["durationMs": .number(Double(duration))])
        )
        return perform(request, render: renderStatus)
    }

    private func logsCommand() -> Int32 {        guard let subcommand = rest.first, subcommand == "tail" else {
            return usageError("logs needs tail")
        }
        var lineCount = 50
        if let index = rest.firstIndex(of: "-n"), index + 1 < rest.count, let value = Int(rest[index + 1]) {
            lineCount = value
        }
        let request = ControlRequest(
            command: ControlCommand.logsTail,
            arguments: .object(["lines": .number(Double(lineCount))])
        )
        return perform(request, render: { data in
            for line in data["lines"]?.arrayValue ?? [] {
                print(line.stringValue ?? line.compactDescription)
            }
        })
    }

    private func launchCommand() -> Int32 {
        guard let app = findAppBundle() else {
            printError(code: "app_unavailable", message: "BarFold.app was not found. Set BARFOLD_APP_PATH or install it in /Applications.")
            return 3
        }
        if (try? client().send(ControlRequest(command: ControlCommand.ping))) != nil {
            return simpleCommand(ControlCommand.status, render: renderStatus)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", app.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            printError(code: "app_unavailable", message: "could not launch \(app.path): \(error.localizedDescription)")
            return 3
        }
        guard process.terminationStatus == 0 else {
            printError(code: "app_unavailable", message: "open exited \(process.terminationStatus)")
            return 3
        }

        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if (try? client().send(ControlRequest(command: ControlCommand.ping))) != nil {
                return simpleCommand(ControlCommand.status, render: renderStatus)
            }
            usleep(150_000)
        }
        printError(code: "app_unavailable", message: "BarFold did not open its control socket within 6s")
        return 3
    }

    // MARK: - Plumbing

    private func client() -> ControlClient {
        ControlClient(timeout: max(3, timeout))
    }

    private func perform(_ request: ControlRequest, render: ((JSONValue) -> Void)?) -> Int32 {
        do {
            let response = try client().send(request)
            guard response.ok else {
                printError(code: response.error?.code ?? "internal_error",
                           message: response.error?.message ?? "unknown error")
                return exitCode(for: response.error?.code)
            }
            let data = response.data ?? .null
            if jsonOutput {
                printData(data)
            } else if let render {
                render(data)
            } else if request.command == ControlCommand.appQuit {
                print("BarFold 正在退出")
            } else {
                print(data.compactDescription)
            }
            return 0
        } catch {
            printError(code: "app_unavailable", message: error.localizedDescription)
            return 3
        }
    }

    private func printData(_ data: JSONValue) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let encoded = try? encoder.encode(data),
           let text = String(data: encoded, encoding: .utf8) {
            print(text)
        } else {
            print(data.compactDescription)
        }
    }

    private func printError(code: String, message: String) {
        if jsonOutput {
            let payload: JSONValue = .object([
                "ok": .bool(false),
                "error": .object([
                    "code": .string(code),
                    "message": .string(message),
                ]),
            ])
            printData(payload)
        } else {
            let text = "barfold: \(message)"
            FileHandle.standardError.write(Data((text + "\n").utf8))
        }
    }

    private func usageError(_ message: String) -> Int32 {
        printError(code: "usage", message: message)
        return 2
    }

    private func exitCode(for code: String?) -> Int32 {
        switch code {
        case ControlErrorCode.appUnavailable:
            return 3
        case ControlErrorCode.usage, ControlErrorCode.invalidArgument:
            return 2
        case ControlErrorCode.timeout:
            return 5
        default:
            return 4
        }
    }

    private func findAppBundle() -> URL? {
        if let raw = ProcessInfo.processInfo.environment["BARFOLD_APP_PATH"],
           !raw.isEmpty {
            let url = URL(fileURLWithPath: raw)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }

        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var candidate = executable
        for _ in 0..<5 {
            candidate = candidate.deletingLastPathComponent()
            if candidate.pathExtension == "app",
               FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [
            "/Applications/BarFold.app",
            "\(home)/Applications/BarFold.app",
        ]
        return paths.first(where: { FileManager.default.fileExists(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Human rendering

    private func renderStatus(_ data: JSONValue) {
        let collapsed = data["collapsed"]?.boolValue ?? false
        let state = collapsed ? "已收起" : "已展开"
        let engine = data["engine"]?.stringValue ?? "?"
        let available = data["engineAvailable"]?.boolValue ?? false
        let version = data["version"]?.stringValue ?? "?"
        let pid = data["pid"]?.intValue ?? 0

        print("BarFold \(version)  pid \(pid)")
        print("状态    \(state)")
        print("引擎    \(engine) \(available ? "" : "(不可用)")")

        if let frame = data["toggleFrame"]?.objectValue {
            let onScreen = data["toggleOnScreen"]?.boolValue ?? false
            print("箭头    x=\(int(frame["x"])) y=\(int(frame["y"])) w=\(int(frame["width"])) h=\(int(frame["height"]))  on-screen=\(onScreen ? "yes" : "no")")
        }
        print("分隔符  length=\(int(data["separatorLength"]))")
        if let screens = data["screens"]?.arrayValue {
            let names = screens.compactMap { screen -> String? in
                guard let name = screen["name"]?.stringValue,
                      let frame = screen["frame"]?.objectValue else { return nil }
                return "\(name) \(int(frame["width"]))×\(int(frame["height"]))"
            }
            print("屏幕    \(names.joined(separator: ", "))")
        }
        if let managers = data["otherManagers"]?.arrayValue, !managers.isEmpty {
            print(colorize("注意    其他菜单栏工具正在运行: \(managers.compactMap(\.stringValue).joined(separator: ", "))", "33"))
        }
        if let settings = data["settings"]?.objectValue {
            print("触发    hover=\(settings["hoverEnabled"]?.boolValue == true ? "on" : "off") delay=\(settings["hoverDelay"]?.doubleValue ?? 0)s  hotkey=\(settings["hotkey"]?.stringValue ?? "none")")
        }
    }

    private func renderProbe(_ data: JSONValue) {
        renderStatus(data)
        print("探针    statusWindows=\(int(data["statusWindowCount"])) visible=\(int(data["visibleStatusWindowCount"])) menuOpen=\(data["menuOpen"]?.boolValue == true ? "yes" : "no")")
        if let canary = data["canaryOnScreen"]?.boolValue {
            print("Canary  on-screen=\(canary ? "yes" : "no")")
        }
        if let verification = data["engineVerification"]?.objectValue,
           let checks = verification["checks"]?.arrayValue {
            print("引擎校验")
            for check in checks {
                let status = check["status"]?.stringValue ?? "?"
                print("  \(symbol(for: status)) \(check["name"]?.stringValue ?? "?")  \(check["detail"]?.stringValue ?? "")")
            }
        }
    }

    private func renderDoctor(_ data: JSONValue) {
        guard let checks = data["checks"]?.arrayValue else {
            printData(data)
            return
        }
        for check in checks {
            let status = check["status"]?.stringValue ?? "?"
            print("\(symbol(for: status)) \(check["name"]?.stringValue ?? "?")  \(check["detail"]?.stringValue ?? "")")
        }
        let ok = data["ok"]?.boolValue ?? false
        print(ok ? colorize("全部通过", "32") : colorize("存在问题", "31"))
    }

    private func renderSettings(_ data: JSONValue) {
        guard let object = data.objectValue else {
            printData(data)
            return
        }
        for key in object.keys.sorted() {
            print("\(key) = \(object[key]?.compactDescription ?? "null")")
        }
    }

    private func renderHotkey(_ data: JSONValue) {
        print("hotkey = \(data["hotkey"]?.stringValue ?? "none")")
        if let keyCode = data["keyCode"]?.intValue, let modifiers = data["modifiers"]?.intValue {
            print("keyCode = \(keyCode)  modifiers = \(modifiers)")
        }
    }

    private func renderEngine(_ data: JSONValue) {
        print("current = \(data["current"]?.stringValue ?? "?")")
        if let available = data["available"]?.arrayValue {
            for engine in available {
                print("- \(engine["name"]?.stringValue ?? "?") available=\(engine["available"]?.boolValue == true ? "yes" : "no")")
            }
        }
        print("override = \(data["override"]?.stringValue ?? "auto")")
    }

    private func symbol(for status: String) -> String {
        switch status {
        case "pass": return colorize("✓", "32")
        case "warn": return colorize("!", "33")
        default: return colorize("✗", "31")
        }
    }

    private func colorize(_ text: String, _ code: String) -> String {
        guard !noColor, isatty(STDOUT_FILENO) == 1 else { return text }
        return "\u{001B}[\(code)m\(text)\u{001B}[0m"
    }

    private func int(_ value: JSONValue?) -> Int {
        value?.intValue ?? 0
    }

    private func printHelp() {
        print("""
        barfold — BarFold 控制接口

        用法:
          barfold status [--json|--human]
          barfold collapse | expand | toggle
          barfold wait collapsed|expanded [--timeout 2000]
          barfold probe
          barfold doctor
          barfold selftest
          barfold settings get
          barfold settings open
          barfold settings set hoverEnabled=false hoverDelay=0.3
          barfold hotkey get | set <combo> | clear
          barfold hover simulate --duration 400
          barfold engine list | select <auto|lengthSpacer|unsupported>
          barfold loginitem status | enable | disable
          barfold update status | check | install
          barfold logs tail [-n 50]
          barfold launch | quit
          barfold --version

        退出码: 0 成功, 2 用法错误, 3 应用未运行, 4 应用错误, 5 超时
        """)
    }
}

exit(CLI(arguments: Array(CommandLine.arguments.dropFirst())).run())
