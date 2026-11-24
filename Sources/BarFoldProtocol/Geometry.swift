import Foundation

public struct Point: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct Rect: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    public func contains(_ point: Point) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    public func intersects(_ other: Rect) -> Bool {
        maxX > other.minX && other.maxX > minX && maxY > other.minY && other.maxY > minY
    }
}

public struct ScreenDescriptor: Codable, Sendable, Equatable {
    public var name: String
    public var frame: Rect
    public var visibleFrame: Rect
    public var safeAreaTop: Double
    public var isMain: Bool
    public var backingScale: Double

    public init(
        name: String,
        frame: Rect,
        visibleFrame: Rect,
        safeAreaTop: Double,
        isMain: Bool,
        backingScale: Double
    ) {
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTop = safeAreaTop
        self.isMain = isMain
        self.backingScale = backingScale
    }
}

public enum MenuBarGeometry {
    /// Smallest length that keeps the separator mounted. AppKit adds 16 pt of
    /// window padding, so this still occupies ~17 pt; 0 makes the item vanish and
    /// drop its autosaved position, which permanently breaks the collapse anchor.
    public static let expandedLength: Double = 1
    public static let maximumCollapsedLength: Double = 10_000
    public static let minimumMenuBarHeight: Double = 30

    public static func menuBarHeight(for screen: ScreenDescriptor, systemThickness: Double) -> Double {
        max(systemThickness, screen.safeAreaTop + 1, minimumMenuBarHeight)
    }

    public static func menuBarBand(for screen: ScreenDescriptor, systemThickness: Double) -> Rect {
        let height = menuBarHeight(for: screen, systemThickness: systemThickness)
        return Rect(
            x: screen.frame.x,
            y: screen.frame.maxY - height,
            width: screen.frame.width,
            height: height
        )
    }

    public static func isInMenuBar(
        point: Point,
        screens: [ScreenDescriptor],
        systemThickness: Double,
        tolerance: Double = 2
    ) -> Bool {
        screens.contains { screen in
            let band = menuBarBand(for: screen, systemThickness: systemThickness)
            return point.x >= band.minX
                && point.x <= band.maxX
                && point.y >= band.minY - tolerance
                && point.y <= band.maxY + tolerance
        }
    }

    public static func screen(containing point: Point, screens: [ScreenDescriptor]) -> ScreenDescriptor? {
        screens.first { $0.frame.contains(point) }
    }

    public static func widestScreenWidth(_ screens: [ScreenDescriptor]) -> Double {
        screens.map(\.frame.width).max() ?? 1440
    }

    /// A separator wide enough to push every item left of it off every display.
    /// The window server clamps the actual length (measured 5016pt on this Mac),
    /// so asking for 10k is intentional: it is a ceiling, not a target.
    public static func collapsedLength(for screens: [ScreenDescriptor]) -> Double {
        let widest = widestScreenWidth(screens)
        return min(maximumCollapsedLength, max(500, widest * 2))
    }

    public static func isOnAnyScreen(_ rect: Rect, screens: [ScreenDescriptor]) -> Bool {
        screens.contains { $0.frame.intersects(rect) }
    }

    /// Converts a CoreGraphics window rect (top-left origin of the main display)
    /// into AppKit screen coordinates (bottom-left origin of the main display).
    public static func appKitRect(fromCoreGraphics rect: Rect, mainScreenHeight: Double) -> Rect {
        Rect(
            x: rect.x,
            y: mainScreenHeight - rect.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}
