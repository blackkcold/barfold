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
    private let itemCatalog = MenuBarItemCatalog()
    private let layoutStore = MenuBarLayoutStore()
    private lazy var mover = MenuBarItemMover(catalog: itemCatalog)
    private var moveJob: MenuBarMoveJob?
    private var undoStack = MenuBarUndoStack()
    private var newItemDetector = MenuBarNewItemDetector()

    var currentMoveJob: MenuBarMoveJob? { moveJob }
    var canUndoItems: Bool { undoStack.canUndo }
    var itemsTrusted: Bool { AXIsProcessTrusted() }

    var onSetCollapsed: ((Bool, String) -> Void)?
    var onToggle: ((String) -> Void)?
    var onQuit: (() -> Void)?
    var onHotkeyChanged: (() -> Void)?
    var onHoverSimulate: ((Int) -> Void)?
    var onOpenSettings: ((String?) -> Void)?
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
            onOpenSettings?(request.arguments?["tab"]?.stringValue)
            return success(id, command, .object(["opened": .bool(true)]))

        case ControlCommand.permissionsStatus:
            return success(id, command, .object(itemCatalog.permissionStatus()))

        case ControlCommand.itemsList:
            guard AXIsProcessTrusted() else {
                return failure(
                    id, command,
                    ControlErrorCode.permissionDenied,
                    "菜单栏图标管理需要辅助功能权限；折叠、悬停、热键仍然零权限。"
                )
            }
            let scan = scanItems()
            return success(id, command, itemsData(scan))

        case ControlCommand.layoutGet:
            return success(id, command, layoutStore.json())

        case ControlCommand.layoutSnapshot:
            guard AXIsProcessTrusted() else {
                return failure(
                    id, command,
                    ControlErrorCode.permissionDenied,
                    "菜单栏图标管理需要辅助功能权限；折叠、悬停、热键仍然零权限。"
                )
            }
            let scan = scanItems()
            _ = layoutStore.snapshot(from: scan.items)
            return success(id, command, .object([
                "layout": layoutStore.json(),
                "managedCount": .number(Double(scan.items.filter(\.isManaged).count)),
                "systemCount": .number(Double(scan.items.filter { $0.kind == .system }.count)),
            ]))

        case ControlCommand.itemsMove:
            guard AXIsProcessTrusted() else {
                return failure(
                    id, command,
                    ControlErrorCode.permissionDenied,
                    "菜单栏图标管理需要辅助功能权限；折叠、悬停、热键仍然零权限。"
                )
            }
            guard let arguments = request.arguments?.objectValue,
                  let rawGroup = arguments["group"]?.stringValue,
                  let group = MenuBarItemGroup(rawValue: rawGroup) else {
                return failure(id, command, ControlErrorCode.invalidArgument, "items.move 需要 ids 与 group (visible|hidden)")
            }
            let ids = arguments["ids"]?.arrayValue?.compactMap(\.stringValue)
                ?? arguments["id"]?.stringValue.map { [$0] }
                ?? []
            guard !ids.isEmpty else {
                return failure(id, command, ControlErrorCode.invalidArgument, "items.move 需要至少一个 id")
            }
            let index = max(0, arguments["index"]?.intValue ?? 0)
            let before = arguments["before"]?.stringValue
            guard let job = startItemMove(ids: ids, group: group, before: before, index: index) else {
                return failure(id, command, ControlErrorCode.conflict, "已有移动任务在执行，或引擎不可用")
            }
            return success(id, command, .object([
                "job": job.json(),
                "started": .bool(true),
            ]))

        case ControlCommand.itemsUndo:
            guard AXIsProcessTrusted() else {
                return failure(id, command, ControlErrorCode.permissionDenied,
                               "菜单栏图标管理需要辅助功能权限。")
            }
            guard let job = undoItems() else {
                return failure(id, command, ControlErrorCode.unsupported, "没有可撤销的操作")
            }
            return success(id, command, .object([
                "job": job.json(),
                "started": .bool(true),
            ]))

        case ControlCommand.itemsJob:
            guard let job = moveJob else {
                return success(id, command, .object(["job": .null, "running": .bool(false)]))
            }
            if let wanted = request.arguments?["id"]?.stringValue, wanted != job.id {
                return failure(id, command, ControlErrorCode.invalidArgument, "未知任务：\(wanted)")
            }
            return success(id, command, .object([
                "job": job.json(),
                "running": .bool(job.isRunning),
            ]))

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

    // MARK: - Menu bar items

    /// Single entry point for every move: the CLI command and the settings page
    /// both call this, so undo snapshots and job coordination cannot diverge.
    @discardableResult
    func startItemMove(
        ids: [String],
        group: MenuBarItemGroup,
        before: String?,
        index: Int,
        steps: [MenuBarBatchStep]? = nil
    ) -> MenuBarMoveJob? {
        if let running = moveJob, running.isRunning { return nil }
        guard statusItems.engine.isAvailable else { return nil }
        if steps == nil {
            undoStack.push(MenuBarUndoEntry(layout: layoutStore.layout, ids: ids))
        }
        let wasCollapsed = statusItems.isCollapsed
        let job = MenuBarMoveJob(ids: ids, group: group, index: index, before: before, steps: steps)
        moveJob = job
        onSetCollapsed?(false, "items.move")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startMove(job: job, wasCollapsed: wasCollapsed)
        }
        return job
    }

    /// Replays the previous layout for the items the last operation touched.
    @discardableResult
    func undoItems() -> MenuBarMoveJob? {
        guard let entry = undoStack.pop() else { return nil }
        let steps = MenuBarUndoPlanner.plan(entry: entry)
        guard !steps.isEmpty else { return nil }
        let group = steps.last?.group ?? .hidden
        return startItemMove(ids: entry.ids, group: group, before: nil, index: 0, steps: steps)
    }

    /// Loads the item list off the main thread. The first accessibility call to
    /// each app costs tens of milliseconds, so this never runs on the UI thread.
    func refreshItems(
        _ completion: @escaping ([MenuBarItemSnapshot], MenuBarCapacity) -> Void
    ) {
        let arrowMinX = statusItems.toggleFrame.map { Double($0.minX) }
        let arrowWidth = statusItems.toggleFrame.map { Double($0.width) } ?? 26
        let screens = ScreenMapping.descriptors
        let catalog = itemCatalog
        let store = layoutStore
        Task.detached(priority: .userInitiated) {
            let scan = catalog.scan(
                arrowMinX: arrowMinX,
                collapsed: false,
                screens: screens.map(\.frame)
            )
            let barWidth = Self.menuBarWidth(arrowMinX: arrowMinX, screens: screens)
            let capacity = MenuBarCapacityCalculator.evaluate(
                items: scan.items,
                arrowWidth: arrowWidth,
                menuBarWidth: barWidth
            )
            await MainActor.run {
                let managed = scan.items.filter(\.isManaged).sorted { $0.x < $1.x }
                store.adopt(liveIDs: managed.map(\.id), observedGroups: Self.observedGroups(in: scan.items))
                let reported = MenuBarItemReport.apply(layout: store.layout, live: scan.items)
                completion(reported, capacity)
            }
        }
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        if let url { NSWorkspace.shared.open(url) }
    }

    /// Called when a new app launches. New extras are moved into the hidden
    /// group's left end, which is where macOS would have put them anyway.
    func handleAppLaunched() {
        guard settings.autoHideNewItems, AXIsProcessTrusted() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.autoHideNewItems()
        }
    }

    /// Seeds the detector at launch, and also runs the auto-hide pass.
    func startNewItemWatcher() {
        guard AXIsProcessTrusted() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.autoHideNewItems()
        }
    }

    private func autoHideNewItems() {
        if let job = moveJob, job.isRunning { return }
        let arrowMinX = statusItems.toggleFrame.map { Double($0.minX) }
        let screens = ScreenMapping.descriptors.map(\.frame)
        let catalog = itemCatalog
        Task.detached(priority: .utility) {
            let scan = catalog.scan(arrowMinX: arrowMinX, collapsed: false, screens: screens)
            await MainActor.run { [weak self] in
                guard let self else { return }
                let fresh = self.newItemDetector.observe(scan.items)
                guard !fresh.isEmpty, self.settings.autoHideNewItems else { return }
                let arrow = arrowMinX ?? 0
                let hidden = scan.items
                    .filter { $0.isManaged && ($0.observedGroup ?? MenuBarItemIdentity.classify(x: $0.x, arrowMinX: arrow)) == .hidden }
                    .sorted { $0.x < $1.x }
                _ = self.startItemMove(
                    ids: fresh.map(\.id),
                    group: .hidden,
                    before: hidden.first?.id,
                    index: 0
                )
            }
        }
    }

    private nonisolated static func observedGroups(in items: [MenuBarItemSnapshot]) -> [String: MenuBarItemGroup] {
        var result: [String: MenuBarItemGroup] = [:]
        for item in items where item.isManaged {
            if let group = item.observedGroup { result[item.id] = group }
        }
        return result
    }

    private func observedGroups(in items: [MenuBarItemSnapshot]) -> [String: MenuBarItemGroup] {
        Self.observedGroups(in: items)
    }

    private nonisolated static func menuBarWidth(arrowMinX: Double?, screens: [ScreenDescriptor]) -> Double {
        if let arrowMinX,
           let host = screens.first(where: { arrowMinX >= $0.frame.x && arrowMinX <= $0.frame.x + $0.frame.width }) {
            return host.frame.width
        }
        return screens.map(\.frame.width).max() ?? 1920
    }

    private func startMove(job: MenuBarMoveJob, wasCollapsed: Bool) {
        guard let arrowFrame = statusItems.toggleFrame else {
            job.fail(code: ControlErrorCode.engineUnavailable, message: "菜单栏几何不可用")
            return
        }
        let arrow = cgRect(arrowFrame)
        // The separator window normally exists; fall back to the arrow's left
        // edge if AppKit has not laid it out yet.
        let separator = statusItems.separatorFrame.map(cgRect)
            ?? Rect(x: arrow.x - 8, y: arrow.y, width: 2, height: arrow.height)
        let screens = ScreenMapping.descriptors.map(\.frame)
        let mover = self.mover
        let catalog = self.itemCatalog
        let ids = job.ids
        let group = job.group
        let index = job.requestedIndex
        let before = job.requestedBefore
        let router = self
        job.update("扫描菜单栏")
        Task.detached(priority: .userInitiated) {
            do {
                let scan = catalog.scan(arrowMinX: arrow.x, collapsed: false, screens: screens)
                if let preset = job.presetSteps {
                    for step in preset {
                        let stepIndex = step.before == nil
                            ? (step.index ?? (step.group == .visible ? 0 : Int.max))
                            : 0
                        let result = try mover.move(
                            id: step.id,
                            to: step.group,
                            before: step.before,
                            index: stepIndex,
                            arrow: arrow,
                            separator: separator,
                            screens: screens
                        )
                        await MainActor.run {
                            job.advance(result)
                            router.layoutStore.apply(result: result)
                        }
                    }
                    await MainActor.run {
                        job.succeed()
                        router.restoreCollapse(wasCollapsed)
                    }
                    return
                }
                let anchor: String? = {
                    if let before { return before }
                    let peers = scan.items
                        .filter { $0.isManaged && !ids.contains($0.id) }
                        .filter { item in
                            (item.observedGroup
                                ?? MenuBarItemIdentity.classify(x: item.x, arrowMinX: arrow.x)) == group
                        }
                        .sorted { $0.x < $1.x }
                    return index < peers.count ? peers[index].id : nil
                }()
                let steps = MenuBarBatchPlanner.plan(ids: ids, group: group, before: anchor, live: scan.items)
                await MainActor.run { job.setSteps(steps) }
                if steps.isEmpty {
                    await MainActor.run {
                        job.succeed()
                        router.restoreCollapse(wasCollapsed)
                    }
                    return
                }
                for step in steps {
                    let result = try mover.move(
                        id: step.id,
                        to: group,
                        before: step.before,
                        index: index,
                        arrow: arrow,
                        separator: separator,
                        screens: screens
                    )
                    await MainActor.run {
                        job.advance(result)
                        router.layoutStore.apply(result: result)
                    }
                }
                await MainActor.run {
                    job.succeed()
                    router.restoreCollapse(wasCollapsed)
                }
            } catch {
                let code: String
                switch error as? MenuBarMoveError {
                case .permissionDenied:
                    code = ControlErrorCode.permissionDenied
                case .itemMissing, .itemNotMovable, .itemOffScreen:
                    code = ControlErrorCode.invalidArgument
                case .verificationFailed, .none:
                    code = "move_failed"
                }
                await MainActor.run {
                    job.fail(code: code, message: error.localizedDescription)
                    router.restoreCollapse(wasCollapsed)
                }
            }
        }
    }

    private func restoreCollapse(_ wasCollapsed: Bool) {
        guard wasCollapsed else { return }
        onSetCollapsed?(true, "items.move.restore")
    }

    /// AppKit rectangles are bottom-left based; CGEvent and AX use top-left.
    private func cgRect(_ frame: NSRect) -> Rect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return Rect(
            x: Double(frame.minX),
            y: Double(primaryHeight - frame.maxY),
            width: Double(frame.width),
            height: Double(frame.height)
        )
    }

    /// One read-only scan, mirroring the observed order into the layout store so
    /// a manual `⌘`-drag in the bar is picked up on the next call.
    private func scanItems() -> MenuBarCatalogScan {
        let arrowMinX = statusItems.toggleFrame.map { Double($0.minX) }
        let screens = ScreenMapping.descriptors.map(\.frame)
        let scan = itemCatalog.scan(
            arrowMinX: arrowMinX,
            collapsed: statusItems.isCollapsed,
            screens: screens
        )
        let managed = scan.items.filter(\.isManaged).sorted { $0.x < $1.x }
        layoutStore.adopt(liveIDs: managed.map(\.id), observedGroups: observedGroups(in: scan.items))
        return scan
    }

    private func itemsData(_ scan: MenuBarCatalogScan) -> JSONValue {
        let reported = MenuBarItemReport.apply(layout: layoutStore.layout, live: scan.items)
        let managed = reported.filter(\.isManaged)
        return .object([
            "axTrusted": .bool(scan.axTrusted),
            "collapsed": .bool(scan.collapsed),
            "arrowMinX": scan.arrowMinX.map { .number($0) } ?? .null,
            "scannedApps": .number(Double(scan.scannedApps)),
            "durationMs": .number((scan.durationMs * 10).rounded() / 10),
            "counts": .object([
                "managed": .number(Double(managed.count)),
                "system": .number(Double(reported.filter { $0.kind == .system }.count)),
                "visible": .number(Double(managed.filter { $0.group == .visible }.count)),
                "hidden": .number(Double(managed.filter { $0.group == .hidden }.count)),
            ]),
            "items": .array(reported.map { itemJSON($0) }),
            "capacity": MenuBarCapacityCalculator.evaluate(
                items: reported,
                arrowWidth: Double(statusItems.toggleFrame?.width ?? 26),
                menuBarWidth: Self.menuBarWidth(
                    arrowMinX: scan.arrowMinX,
                    screens: ScreenMapping.descriptors
                )
            ).json(),
            "canUndo": .bool(undoStack.canUndo),
            "layout": layoutStore.json(),
        ])
    }

    private func itemJSON(_ item: MenuBarItemSnapshot) -> JSONValue {
        .object([
            "id": .string(item.id),
            "bundleID": .string(item.bundleID),
            "appName": .string(item.appName),
            "title": .string(item.title),
            "detail": .string(item.detail),
            "kind": .string(item.kind.rawValue),
            "x": .number((item.x * 10).rounded() / 10),
            "width": .number((item.width * 10).rounded() / 10),
            "group": .string(item.group.rawValue),
            "index": .number(Double(item.index)),
            "observedGroup": item.observedGroup.map { .string($0.rawValue) } ?? .null,
            "managed": .bool(item.isManaged),
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
