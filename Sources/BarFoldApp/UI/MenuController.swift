import AppKit

@MainActor
final class MenuController: NSObject {
    private let settings: SettingsStore

    var isCollapsed: () -> Bool = { false }
    var engineAvailable: () -> Bool = { true }
    var safeModeActive: () -> Bool = { false }
    var onToggle: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onToggleSafeMode: () -> Void = {}
    var onCheckForUpdates: () -> Void = {}
    var onAbout: () -> Void = {}
    var onQuit: () -> Void = {}

    init(settings: SettingsStore) {
        self.settings = settings
        super.init()
    }

    func show(from item: NSStatusItem) {
        guard let button = item.button else { return }
        let menu = buildMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let header = NSMenuItem(
            title: "BarFold · \(isCollapsed() ? L10n.collapsed : L10n.expanded)",
            action: nil,
            keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)

        if !engineAvailable() {
            let warning = NSMenuItem(title: L10n.noEngine, action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
        }

        let toggle = NSMenuItem(
            title: isCollapsed() ? L10n.expand : L10n.collapse,
            action: #selector(toggleAction),
            keyEquivalent: ""
        )
        toggle.target = self
        toggle.isEnabled = engineAvailable()
        menu.addItem(toggle)

        menu.addItem(.separator())

        let hover = NSMenuItem(
            title: L10n.t("悬停菜单栏空白处展开", "Expand when hovering empty menu bar"),
            action: #selector(toggleHover),
            keyEquivalent: ""
        )
        hover.target = self
        hover.state = settings.hoverEnabled ? .on : .off
        menu.addItem(hover)

        let autoCollapse = NSMenuItem(
            title: L10n.t("离开后自动收回", "Collapse after the pointer leaves"),
            action: #selector(toggleAutoCollapse),
            keyEquivalent: ""
        )
        autoCollapse.target = self
        autoCollapse.state = settings.autoCollapseEnabled ? .on : .off
        menu.addItem(autoCollapse)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: L10n.settings, action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let safeMode = NSMenuItem(
            title: safeModeActive() ? L10n.exitSafeMode : L10n.safeMode,
            action: #selector(toggleSafeMode),
            keyEquivalent: ""
        )
        safeMode.target = self
        safeMode.toolTip = L10n.safeModeHelp
        menu.addItem(safeMode)

        let updates = NSMenuItem(title: L10n.checkForUpdates, action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)

        menu.addItem(.separator())

        let about = NSMenuItem(title: L10n.about, action: #selector(about), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: L10n.quit, action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func toggleAction() { onToggle() }
    @objc private func toggleHover() { settings.hoverEnabled.toggle() }
    @objc private func toggleAutoCollapse() { settings.autoCollapseEnabled.toggle() }
    @objc private func openSettings() { onOpenSettings() }
    @objc private func toggleSafeMode() { onToggleSafeMode() }
    @objc private func checkForUpdates() { onCheckForUpdates() }
    @objc private func about() { onAbout() }
    @objc private func quit() { onQuit() }
}

extension Notification.Name {
    static let barFoldStateDidChange = Notification.Name("BarFoldStateDidChange")
}
