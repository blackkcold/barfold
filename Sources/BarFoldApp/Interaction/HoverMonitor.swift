import AppKit
import BarFoldProtocol

@MainActor
final class HoverMonitor {
    private let settings: SettingsStore
    private var timer: Timer?
    private var machine = HoverStateMachine()
    private var itemFrames: [Rect] = []
    private var lastFrameRefresh = Date.distantPast
    private var lastPoint: Point?

    var isCollapsed: () -> Bool = { true }
    var isEnabled: () -> Bool = { true }
    var toggleFrame: () -> Rect? = { nil }
    var onHover: (() -> Void)?

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func start() {
        stop()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
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

    func reset() {
        machine.reset()
        lastPoint = nil
    }

    private func tick() {
        guard isEnabled(), settings.hoverEnabled, isCollapsed() else {
            reset()
            return
        }

        let now = Date()
        let mouse = NSEvent.mouseLocation
        let point = Point(x: Double(mouse.x), y: Double(mouse.y))
        let screens = ScreenMapping.descriptors

        guard MenuBarGeometry.isInMenuBar(
            point: point,
            screens: screens,
            systemThickness: ScreenMapping.systemThickness
        ) else {
            reset()
            return
        }

        // Keep hover to the status-item half of the bar, away from app menus.
        guard let screen = MenuBarGeometry.screen(containing: point, screens: screens),
              point.x >= screen.frame.midX else {
            reset()
            return
        }

        if let toggle = toggleFrame(), toggle.contains(point) {
            reset()
            return
        }

        // Never expand while the user is already browsing a menu.
        if MenuBarProbe.hasOpenMenu() {
            reset()
            return
        }

        // Dwell: moving more than 12pt restarts the delay.
        if let lastPoint,
           hypot(point.x - lastPoint.x, point.y - lastPoint.y) > 12 {
            machine.reset()
        }
        lastPoint = point

        refreshItemFramesIfNeeded(now: now)
        let overItem = itemFrames.contains { $0.contains(point) }
        if machine.update(
            inMenuBar: true,
            overItem: overItem,
            now: now,
            delay: settings.hoverDelay
        ) {
            onHover?()
        }
    }

    private func refreshItemFramesIfNeeded(now: Date) {
        guard now.timeIntervalSince(lastFrameRefresh) > 0.5 else { return }
        lastFrameRefresh = now
        itemFrames = MenuBarProbe.statusItemFrames()
    }
}
