import AppKit
import BarFoldProtocol

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: SettingsStore!
    private var statusItems: StatusItemController!
    private var menuController: MenuController!
    private var eventLog: EventLog!
    private var capability: CapabilityReport!
    private var probe: ProbeService!
    private var router: CommandRouter!
    private var controlServer: ControlServer!
    private var hoverMonitor: HoverMonitor!
    private var autoCollapse: AutoCollapseController!
    private var hotkeyManager: HotkeyManager!
    private var hotkeyError: String?
    private var updateController: UpdateController!
    private var launchStabilizer: LaunchStabilizer?
    private var lockDescriptor: Int32 = -1
    private var safeMode = false
    private let startedAt = Date()
    private var engineDegradedReason: String?
    private var settingsWindowController: SettingsWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private let loginItemManager = LoginItemManager()
    private var isFinishingOnboarding = false

    private var testMode: Bool {
        ProcessInfo.processInfo.environment["BARFOLD_TEST_MODE"] == "1"
            || CommandLine.arguments.contains("--test-mode")
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSLog("BarFold: willFinishLaunching pid=%d bundle=%@", getpid(), Bundle.main.bundleIdentifier ?? "nil")
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("BarFold: didFinishLaunching start")
        let acquired = acquireSingleInstanceLock()
        NSLog("BarFold: lock acquired=%d", acquired ? 1 : 0)
        guard acquired else {
            activateExistingInstanceAndExit()
            return
        }

        try? BarFoldPaths.ensureSupportDirectory()
        eventLog = EventLog()
        settings = SettingsStore()
        capability = CapabilityDetector.detect(override: settings.engineOverride)
        safeMode = ProcessInfo.processInfo.environment["BARFOLD_SAFE_MODE"] == "1"
            || NSEvent.modifierFlags.contains(.option)

        updateController = UpdateController()
        updateController.setAutomaticallyChecks(settings.updateAutomatically)
        updateController.onStatusChange = { [weak self] in
            self?.writeState()
        }

        statusItems = StatusItemController(capability: capability, testMode: testMode)
        menuController = MenuController(settings: settings)
        wireMenu()

        statusItems.onToggle = { [weak self] in
            self?.toggle(reason: "click")
        }
        statusItems.onMenu = { [weak self] item in
            self?.menuController.show(from: item)
        }

        hoverMonitor = HoverMonitor(settings: settings)
        hoverMonitor.isCollapsed = { [weak self] in self?.statusItems.isCollapsed ?? true }
        hoverMonitor.isEnabled = { [weak self] in !(self?.safeMode ?? true) }
        hoverMonitor.toggleFrame = { [weak self] in
            guard let frame = self?.statusItems.toggleFrame else { return nil }
            return Rect(
                x: Double(frame.origin.x),
                y: Double(frame.origin.y),
                width: Double(frame.width),
                height: Double(frame.height)
            )
        }
        hoverMonitor.onHover = { [weak self] in
            self?.setCollapsed(false, reason: "hover")
        }
        hoverMonitor.start()

        autoCollapse = AutoCollapseController(settings: settings)
        autoCollapse.isCollapsed = { [weak self] in self?.statusItems.isCollapsed ?? true }
        autoCollapse.isEnabled = { [weak self] in !(self?.safeMode ?? true) }
        autoCollapse.onCollapse = { [weak self] in
            self?.setCollapsed(true, reason: "auto")
        }
        autoCollapse.start()

        hotkeyManager = HotkeyManager { [weak self] in
            self?.toggle(reason: "hotkey")
        }

        probe = ProbeService(
            statusItems: statusItems,
            settings: settings,
            capability: capability,
            startedAt: startedAt,
            testMode: testMode
        )
        probe.safeMode = { [weak self] in self?.safeMode ?? false }
        probe.version = { [weak self] in self?.appVersion ?? "0.1.0" }
        probe.socketPath = BarFoldPaths.socketURL.path
        probe.hotkeyError = { [weak self] in self?.hotkeyError }
        probe.loginItemStatus = { [weak self] in self?.loginItemManager.status().json }
        probe.updateStatus = { [weak self] in self?.updateController.status }

        router = CommandRouter(
            settings: settings,
            statusItems: statusItems,
            probe: probe,
            eventLog: eventLog,
            capability: capability,
            startedAt: startedAt,
            version: appVersion,
            testMode: testMode
        )
        router.onSetCollapsed = { [weak self] collapsed, reason in
            self?.setCollapsed(collapsed, reason: reason)
        }
        router.onToggle = { [weak self] reason in
            self?.toggle(reason: reason)
        }
        router.onQuit = { NSApp.terminate(nil) }
        router.onOpenSettings = { [weak self] in self?.openSettings(tab: .general) }
        router.onHotkeyChanged = { [weak self] in self?.applyHotkey() }
        router.onHoverSimulate = { [weak self] durationMs in self?.simulateHover(durationMs) }
        router.updateStatus = { [weak self] in
            self?.updateController.status ?? .object([:])
        }
        router.onUpdateCheck = { [weak self] in
            guard let self else { return .object(["configured": false]) }
            if self.updateController.checkForUpdates() {
                return .object(["started": true, "configured": true])
            }
            return .object([
                "configured": false,
                "reason": "Sparkle is not configured in this build",
            ])
        }
        router.loginItemStatus = { [weak self] in
            self?.loginItemManager.status().json ?? .object([:])
        }
        router.onLoginItemChange = { [weak self] enabled in
            guard let self else {
                return .failure(NSError(
                    domain: "BarFold",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "BarFold is shutting down"]
                ))
            }
            switch self.setLoginItem(enabled) {
            case .success(let snapshot): return .success(snapshot.json)
            case .failure(let error): return .failure(error)
            }
        }

        controlServer = ControlServer { [weak self] request in
            guard let self, let router = self.router else {
                return .failure(
                    id: request.id,
                    command: request.command,
                    code: ControlErrorCode.internalError,
                    message: "BarFold is shutting down"
                )
            }
            return MainActor.assumeIsolated {
                router.handle(request)
            }
        }
        do {
            try controlServer.start()
            eventLog.log("control_server_started", [
                "socket": .string(BarFoldPaths.socketURL.path),
            ])
        } catch {
            eventLog.log("control_server_failed", [
                "message": .string(error.localizedDescription),
            ])
        }

        eventLog.log("launch", [
            "version": .string(appVersion),
            "os": .string(capability.osVersion),
            "engine": .string(capability.kind.rawValue),
            "engineAvailable": .bool(capability.kind == .lengthSpacer),
            "testMode": .bool(testMode),
            "safeMode": .bool(safeMode),
        ])
        applyHotkey()
        writeState()
        NSLog("BarFold: launch complete engine=%@ toggleFrame=%@", capability.kind.rawValue,
              statusItems.toggleFrame.map { NSStringFromRect($0) } ?? "nil")

        // The status item windows are placed after the first run-loop turn.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.writeState()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        if !safeMode, settings.hasCompletedOnboarding, settings.lastCollapsed {
            startLaunchStabilizer(reason: "launch")
        }

        if !testMode, !safeMode, !settings.hasCompletedOnboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.showOnboarding()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSLog("BarFold: willTerminate")
        launchStabilizer?.cancel()
        hoverMonitor?.stop()
        autoCollapse?.stop()
        hotkeyManager?.unregister()
        // Never leave the user's menu bar folded after BarFold is gone.
        if let statusItems, statusItems.engine.isAvailable, statusItems.isCollapsed {
            try? statusItems.engine.expand()
        }
        controlServer?.stop()
        eventLog?.log("terminate", ["version": .string(appVersion)])
        releaseSingleInstanceLock()
    }

    // MARK: - Actions

    func toggle(reason: String) {
        if ["click", "menu", "cli"].contains(reason) {
            launchStabilizer?.cancel()
        }
        setCollapsed(!statusItems.isCollapsed, reason: reason)
    }

    func setCollapsed(_ collapsed: Bool, reason: String) {
        guard let statusItems, statusItems.engine.isAvailable else {
            eventLog?.log("collapse_refused", ["reason": .string(capability.detail)])
            return
        }

        if ["click", "menu", "cli", "safe-mode"].contains(reason) {
            launchStabilizer?.cancel()
        }

        do {
            if collapsed {
                try statusItems.engine.collapse()
            } else {
                try statusItems.engine.expand()
            }
            statusItems.refreshIcon()
             settings.lastCollapsed = collapsed
            if collapsed {
                autoCollapse?.disarm()
            } else if ["hover", "hotkey", "click", "menu", "hover-simulate"].contains(reason) {
                autoCollapse?.arm()
            }
            writeState()
            eventLog.log(collapsed ? "collapse" : "expand", ["reason": .string(reason)])
            NotificationCenter.default.post(name: .barFoldStateDidChange, object: nil)

            if collapsed {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.verifyCollapsedState()
                }
            }
        } catch {
            eventLog.log("engine_error", ["message": .string(error.localizedDescription)])
            try? statusItems.engine.expand()
            statusItems.refreshIcon()
            showError(error.localizedDescription)
        }
    }

    private func verifyCollapsedState() {
        guard statusItems.isCollapsed else { return }
        let verification = statusItems.engine.verify()
        eventLog.log("engine_verification", [
            "ok": .bool(verification.ok),
            "checks": .array(verification.checks.map { check in
                .object([
                    "name": .string(check.name),
                    "status": .string(check.status),
                    "detail": .string(check.detail),
                ])
            }),
        ])
        guard !verification.ok else {
            engineDegradedReason = nil
            return
        }

        let message = verification.checks
            .filter { $0.status == "fail" }
            .map { "\($0.name): \($0.detail)" }
            .joined(separator: "; ")
        engineDegradedReason = message
        eventLog.log("engine_degraded", ["message": .string(message)])
        try? statusItems.engine.expand()
        statusItems.refreshIcon()
        settings.lastCollapsed = false
        writeState()
    }

    private func startLaunchStabilizer(reason: String) {
        launchStabilizer?.cancel()
        let stabilizer = LaunchStabilizer()
        launchStabilizer = stabilizer
        stabilizer.start { [weak self] stable in
            guard let self, self.settings.lastCollapsed else { return }
            self.eventLog.log("layout_stable", [
                "stable": .bool(stable),
                "reason": .string(reason),
            ])
            self.setCollapsed(true, reason: "restore")
        }
    }

    private func applyHotkey() {
        guard let hotkeyManager else { return }
        let combo = settings.hotkey
        switch hotkeyManager.register(combo) {
        case .success:
            hotkeyError = nil
            eventLog?.log("hotkey_registered", [
                "combo": .string(combo?.displayString ?? "none"),
            ])
        case .failure(let error):
            hotkeyError = error.localizedDescription
            eventLog?.log("hotkey_failed", [
                "combo": .string(combo?.displayString ?? "none"),
                "message": .string(error.localizedDescription),
            ])
        }
    }

    private func simulateHover(_ durationMs: Int) {
        launchStabilizer?.cancel()
        setCollapsed(false, reason: "hover-simulate")
        autoCollapse.simulateHover(duration: Double(durationMs) / 1000)
        eventLog.log("hover_simulate", [
            "durationMs": .number(Double(durationMs)),
        ])
    }

    @objc private func screenParametersChanged() {
        guard let statusItems, statusItems.engine.isAvailable else { return }
        let wasCollapsed = statusItems.isCollapsed
        if wasCollapsed {
            try? statusItems.engine.expand()
        }
        if let engine = statusItems.engine as? LengthSpacerEngine {
            engine.updateCollapsedLength(
                CGFloat(MenuBarGeometry.collapsedLength(for: ScreenMapping.descriptors))
            )
        }
        if wasCollapsed {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.setCollapsed(true, reason: "screen-change")
            }
        }
        writeState()
    }

    @objc private func workspaceWillSleep() {
        if statusItems.isCollapsed {
            setCollapsed(false, reason: "sleep")
        }
    }

    @objc private func workspaceDidWake() {
        guard settings.hasCompletedOnboarding, settings.lastCollapsed, !safeMode else { return }
        startLaunchStabilizer(reason: "wake")
    }

    private func wireMenu() {
        menuController.isCollapsed = { [weak self] in self?.statusItems.isCollapsed ?? false }
        menuController.engineAvailable = { [weak self] in self?.statusItems.engine.isAvailable ?? false }
        menuController.safeModeActive = { [weak self] in self?.safeMode ?? false }
        menuController.onToggle = { [weak self] in self?.toggle(reason: "menu") }
        menuController.onOpenSettings = { [weak self] in self?.openSettings(tab: .general) }
        menuController.onToggleSafeMode = { [weak self] in self?.toggleSafeMode() }
        menuController.onCheckForUpdates = { [weak self] in self?.showUpdates() }
        menuController.onAbout = { [weak self] in self?.openSettings(tab: .about) }
        menuController.onQuit = { NSApp.terminate(nil) }
    }

    private func toggleSafeMode() {
        safeMode.toggle()
        if safeMode {
            setCollapsed(false, reason: "safe-mode")
        }
        eventLog.log("safe_mode", ["enabled": .bool(safeMode)])
    }

    private func openSettings(tab: SettingsTab = .general) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                settings: settings,
                actions: makeSettingsActions()
            )
        }
        settingsWindowController?.show(tab: tab)
    }

    private func makeSettingsActions() -> SettingsActions {
        SettingsActions(
            isCollapsed: { [weak self] in self?.statusItems.isCollapsed ?? false },
            toggleCollapsed: { [weak self] in self?.toggle(reason: "menu") },
            expand: { [weak self] in self?.setCollapsed(false, reason: "settings") },
            doctor: { [weak self] in self?.probe.doctorData() ?? .null },
            selfTest: { [weak self] in self?.router.selfTestData() ?? .null },
            screens: { ScreenMapping.descriptors },
            engineDescription: { [weak self] in self?.capability.detail ?? "" },
            hotkeyError: { [weak self] in self?.hotkeyError },
            setHotkey: { [weak self] combo in self?.updateHotkey(combo) },
            loginItemStatus: { [weak self] in self?.loginItemManager.status() ?? .disabled },
            setLoginItem: { [weak self] enabled in
                self?.setLoginItem(enabled)
                    ?? .failure(NSError(
                        domain: "BarFold",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "BarFold is shutting down"]
                    ))
            },
            openLoginItemSettings: { [weak self] in self?.loginItemManager.openSystemSettings() },
            checkForUpdates: { [weak self] in self?.showUpdates() },
            setAutomaticUpdates: { [weak self] enabled in
                self?.updateController?.setAutomaticallyChecks(enabled)
            },
            quit: { NSApp.terminate(nil) },
            resetOnboarding: { [weak self] in self?.resetOnboarding() },
            arrowFrame: { [weak self] in self?.arrowFrameString ?? "—" },
            socketPath: { BarFoldPaths.socketURL.path }
        )
    }

    private func updateHotkey(_ combo: KeyCombo?) {
        settings.hotkey = combo
        applyHotkey()
    }

    private func setLoginItem(_ enabled: Bool) -> Result<LoginItemSnapshot, Error> {
        do {
            let snapshot = try loginItemManager.setEnabled(enabled)
            eventLog.log("login_item", [
                "enabled": .bool(snapshot.enabled),
                "backend": .string(snapshot.backend),
            ])
            return .success(snapshot)
        } catch {
            eventLog.log("login_item_failed", [
                "message": .string(error.localizedDescription),
            ])
            return .failure(error)
        }
    }

    private func showOnboarding() {
        if let onboardingWindowController {
            onboardingWindowController.show()
            return
        }
        let actions = OnboardingActions(
            complete: { [weak self] in self?.finishOnboarding() },
            setLoginItem: { [weak self] enabled in
                self?.setLoginItem(enabled)
                    ?? .failure(NSError(
                        domain: "BarFold",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "BarFold is shutting down"]
                    ))
            },
            loginItemStatus: { [weak self] in self?.loginItemManager.status() ?? .disabled }
        )
        onboardingWindowController = OnboardingWindowController(actions: actions)
        onboardingWindowController?.show()
        eventLog.log("onboarding_shown")
    }

    private func finishOnboarding() {
        guard !isFinishingOnboarding else { return }
        isFinishingOnboarding = true
        settings.hasCompletedOnboarding = true
        onboardingWindowController?.close()
        onboardingWindowController = nil
        eventLog.log("onboarding_completed")
        if settings.lastCollapsed {
            startLaunchStabilizer(reason: "onboarding")
        }
        isFinishingOnboarding = false
    }

    private func resetOnboarding() {
        settings.hasCompletedOnboarding = false
        settingsWindowController?.close()
        showOnboarding()
    }

    private var arrowFrameString: String {
        guard let frame = statusItems.toggleFrame else { return "—" }
        return "x=\(Int(frame.origin.x)) y=\(Int(frame.origin.y)) \(Int(frame.width))×\(Int(frame.height))"
    }

    private func showUpdates() {
        if updateController.checkForUpdates() {
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.checkForUpdates
        alert.informativeText = L10n.t(
            "更新检查尚未配置：需要固定签名与 Sparkle EdDSA 公钥。",
            "Update checks are not configured: the fixed signature and Sparkle EdDSA public key are required."
        )
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L10n.t("BarFold 遇到问题", "BarFold hit a problem")
        alert.informativeText = message + "\n\n" + L10n.t("已自动恢复为展开状态，菜单栏不会留在异常状态。",
                                                          "BarFold expanded the bar automatically so it is not left in a broken state.")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - State

    private func writeState() {
        var state: [String: Any] = [
            "version": appVersion,
            "pid": getpid(),
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "collapsed": statusItems.isCollapsed,
            "engine": statusItems.engine.kind.rawValue,
            "engineAvailable": statusItems.engine.isAvailable,
            "engineDegradedReason": engineDegradedReason ?? "",
            "testMode": testMode,
            "safeMode": safeMode,
            "osVersion": capability.osVersion,
            "capability": capability.detail,
            "socketPath": BarFoldPaths.socketURL.path,
            "updateConfigured": updateController?.isConfigured ?? false,
            "updateAvailable": updateController?.updateAvailable ?? false,
            "screens": ScreenMapping.descriptors.map { screen -> [String: Any] in
                [
                    "name": screen.name,
                    "frame": ["x": screen.frame.x, "y": screen.frame.y,
                              "width": screen.frame.width, "height": screen.frame.height],
                    "visibleFrame": ["x": screen.visibleFrame.x, "y": screen.visibleFrame.y,
                                     "width": screen.visibleFrame.width, "height": screen.visibleFrame.height],
                    "safeAreaTop": screen.safeAreaTop,
                    "isMain": screen.isMain,
                ]
            },
        ]
        if let frame = statusItems.toggleFrame {
            state["toggleFrame"] = ["x": frame.origin.x, "y": frame.origin.y,
                                    "width": frame.width, "height": frame.height]
        }
        if let frame = statusItems.separatorFrame {
            state["separatorFrame"] = ["x": frame.origin.x, "y": frame.origin.y,
                                       "width": frame.width, "height": frame.height]
        }
        state["separatorLength"] = statusItems.separatorLength

        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: BarFoldPaths.stateURL, options: [.atomic])
        _ = chmod(BarFoldPaths.stateURL.path, 0o600)
    }

    // MARK: - Single instance

    private func acquireSingleInstanceLock() -> Bool {
        try? BarFoldPaths.ensureSupportDirectory()
        let descriptor = open(BarFoldPaths.lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return true }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            close(descriptor)
            return false
        }
        lockDescriptor = descriptor
        ftruncate(descriptor, 0)
        let pid = "\(getpid())\n"
        _ = pid.withCString { write(descriptor, $0, strlen($0)) }
        return true
    }

    private func releaseSingleInstanceLock() {
        guard lockDescriptor >= 0 else { return }
        flock(lockDescriptor, LOCK_UN)
        close(lockDescriptor)
        lockDescriptor = -1
    }

    private func activateExistingInstanceAndExit() {
        NSLog("BarFold: existing instance found, exiting")
        if let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: BarFoldPaths.bundleIdentifier)
            .first(where: { $0.processIdentifier != getpid() }) {
            app.activate(options: [.activateIgnoringOtherApps])
        }
        exit(0)
    }
}
