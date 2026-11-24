import AppKit
import BarFoldProtocol

@MainActor
final class AutoCollapseController {
    private let settings: SettingsStore
    private var timer: Timer?
    private var machine = AutoCollapseStateMachine()
    private var simulatedLeaveAt: Date?
    private var isArmed = false

    var isCollapsed: () -> Bool = { false }
    var isEnabled: () -> Bool = { true }
    var onCollapse: (() -> Void)?

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func start() {
        stop()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Auto-collapse must only fire after the user opened the bar (hover,
    /// hotkey, click, menu). Otherwise a fresh launch would hide the bar
    /// without any user action.
    func arm() {
        isArmed = true
        machine.reset()
        simulatedLeaveAt = nil
    }

    func disarm() {
        isArmed = false
        machine.reset()
        simulatedLeaveAt = nil
    }

    /// Test hook: keep the app expanded for `duration`, then collapse once. It
    /// deliberately bypasses the real pointer so automated runs are stable.
    func simulateHover(duration: TimeInterval) {
        isArmed = true
        simulatedLeaveAt = Date().addingTimeInterval(duration)
        machine.reset()
    }

    private func tick() {
        guard isArmed, isEnabled(), settings.autoCollapseEnabled, !isCollapsed() else {
            machine.reset()
            return
        }

        let now = Date()
        if let simulatedLeaveAt {
            if now < simulatedLeaveAt {
                machine.reset()
                return
            }
            self.simulatedLeaveAt = nil
            onCollapse?()
            return
        }

        let mouse = NSEvent.mouseLocation
        let point = Point(x: Double(mouse.x), y: Double(mouse.y))
        let inMenuBar = MenuBarGeometry.isInMenuBar(
            point: point,
            screens: ScreenMapping.descriptors,
            systemThickness: ScreenMapping.systemThickness
        )
        if machine.update(
            inMenuBar: inMenuBar,
            menuOpen: MenuBarProbe.hasOpenMenu(),
            now: now,
            delay: settings.collapseDelay
        ) {
            onCollapse?()
        }
    }
}
