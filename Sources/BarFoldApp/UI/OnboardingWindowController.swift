import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let actions: OnboardingActions
    private var window: NSWindow?
    private var didComplete = false

    init(actions: OnboardingActions) {
        self.actions = actions
        super.init()
    }

    func show() {
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
        didComplete = true
        window?.close()
    }

    private func createWindow() {
        let hosting = NSHostingView(rootView: OnboardingView(actions: actions))
        hosting.frame = NSRect(x: 0, y: 0, width: 620, height: 740)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 740),
            styleMask: [.titled, .closable, .fullSizeContentView],
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
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.center()
        window.delegate = self
        window.collectionBehavior = [.moveToActiveSpace]
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        guard !didComplete else { return }
        didComplete = true
        actions.complete()
    }
}
