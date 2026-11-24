import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settings: SettingsStore
    private let actions: SettingsActions
    private let navigation = SettingsNavigationModel()
    private var window: NSWindow?

    init(settings: SettingsStore, actions: SettingsActions) {
        self.settings = settings
        self.actions = actions
        super.init()
    }

    func show(tab: SettingsTab = .general) {
        navigation.tab = tab
        if window == nil {
            createWindow()
        }
        guard let window else { return }
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeKey()
    }

    func close() {
        window?.close()
    }

    private func createWindow() {
        let root = SettingsView(settings: settings, navigation: navigation, actions: actions)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 780, height: 560)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.title = "BarFold"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.minSize = NSSize(width: 760, height: 540)
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.center()
        window.delegate = self
        window.collectionBehavior = [.moveToActiveSpace]
        self.window = window
    }
}
