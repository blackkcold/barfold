import AppKit

@MainActor
func runBarFold() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
    NSLog("BarFold: run loop returned")
}

MainActor.assumeIsolated {
    runBarFold()
}
