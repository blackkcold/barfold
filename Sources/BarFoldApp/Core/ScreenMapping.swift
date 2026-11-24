import AppKit
import BarFoldProtocol

extension NSScreen {
    var barFoldDescriptor: ScreenDescriptor {
        ScreenDescriptor(
            name: localizedName,
            frame: Rect(
                x: Double(frame.origin.x),
                y: Double(frame.origin.y),
                width: Double(frame.width),
                height: Double(frame.height)
            ),
            visibleFrame: Rect(
                x: Double(visibleFrame.origin.x),
                y: Double(visibleFrame.origin.y),
                width: Double(visibleFrame.width),
                height: Double(visibleFrame.height)
            ),
            safeAreaTop: Double(safeAreaInsets.top),
            isMain: self == NSScreen.main,
            backingScale: Double(backingScaleFactor)
        )
    }
}

enum ScreenMapping {
    static var descriptors: [ScreenDescriptor] {
        NSScreen.screens.map(\.barFoldDescriptor)
    }

    static var systemThickness: Double {
        Double(NSStatusBar.system.thickness)
    }

    static var mainScreenHeight: Double {
        Double(NSScreen.screens.first(where: { $0 == NSScreen.main })?.frame.height ?? 0)
    }

    static func coreGraphicsRect(from window: NSWindow) -> Rect {
        let f = window.frame
        return Rect(x: f.origin.x, y: f.origin.y, width: f.width, height: f.height)
    }

    static func appKitRect(fromCGWindowBounds bounds: [String: Any]) -> Rect? {
        guard let x = bounds["X"] as? Double,
              let y = bounds["Y"] as? Double,
              let width = bounds["Width"] as? Double,
              let height = bounds["Height"] as? Double else {
            return nil
        }
        return MenuBarGeometry.appKitRect(
            fromCoreGraphics: Rect(x: x, y: y, width: width, height: height),
            mainScreenHeight: mainScreenHeight
        )
    }
}
