import AppKit
import Foundation

// Draws the BarFold app icon in 1024-point space, then rasterizes it at every
// iconset size. Run: swift scripts/generate-icon.swift
// Output: Resources/AppIcon.iconset + Resources/AppIcon.icns

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let projectRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let iconsetURL = projectRoot.appendingPathComponent("Resources/AppIcon.iconset", isDirectory: true)
let icnsURL = projectRoot.appendingPathComponent("Resources/AppIcon.icns")
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let indigo = NSColor(calibratedRed: 0.36, green: 0.36, blue: 0.97, alpha: 1)
let teal = NSColor(calibratedRed: 0.13, green: 0.78, blue: 0.69, alpha: 1)

func drawIconIn1024() {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    let square = NSRect(x: 100, y: 100, width: 824, height: 824)
    let path = NSBezierPath(roundedRect: square, xRadius: 185, yRadius: 185)

    // Soft drop shadow so the icon lifts off the Finder background.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 38
    shadow.shadowOffset = NSSize(width: 0, height: -16)
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Main gradient.
    let gradient = NSGradient(colors: [indigo, teal])!
    gradient.draw(in: path, angle: -45)

    // Top sheen, clipped to the icon shape.
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    let sheen = NSGradient(colors: [NSColor.white.withAlphaComponent(0.22),
                                    NSColor.white.withAlphaComponent(0.0)])!
    sheen.draw(in: NSRect(x: 100, y: 520, width: 824, height: 404), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Inner rim.
    NSColor.white.withAlphaComponent(0.14).setStroke()
    path.lineWidth = 3
    path.stroke()

    // Fold glyph: arrow-left-to-line.
    let glyph = NSBezierPath()
    glyph.lineWidth = 44
    glyph.lineCapStyle = .round
    glyph.lineJoinStyle = .round
    glyph.move(to: NSPoint(x: 340, y: 512))
    glyph.line(to: NSPoint(x: 640, y: 512))
    glyph.move(to: NSPoint(x: 456, y: 416))
    glyph.line(to: NSPoint(x: 340, y: 512))
    glyph.line(to: NSPoint(x: 456, y: 608))

    let bar = NSBezierPath(
        roundedRect: NSRect(x: 640, y: 344, width: 46, height: 336),
        xRadius: 23,
        yRadius: 23
    )

    NSGraphicsContext.saveGraphicsState()
    let glyphShadow = NSShadow()
    glyphShadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    glyphShadow.shadowBlurRadius = 16
    glyphShadow.shadowOffset = NSSize(width: 0, height: -8)
    glyphShadow.set()
    NSColor.white.setStroke()
    glyph.stroke()
    NSColor.white.setFill()
    bar.fill()
    NSGraphicsContext.restoreGraphicsState()
}

func renderPNG(pixelSize: Int) -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Could not allocate \(pixelSize)px bitmap")
    }
    rep.size = NSSize(width: pixelSize, height: pixelSize)
    guard let graphicsContext = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("Could not create graphics context")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    let scale = CGFloat(pixelSize) / 1024.0
    graphicsContext.cgContext.scaleBy(x: scale, y: scale)
    drawIconIn1024()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode \(pixelSize)px PNG")
    }
    return data
}

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, size) in variants {
    let data = renderPNG(pixelSize: size)
    try data.write(to: iconsetURL.appendingPathComponent(name))
}

// Keep a 1024 preview next to the iconset for quick visual review.
try renderPNG(pixelSize: 1024).write(to: projectRoot.appendingPathComponent("Resources/AppIcon-preview.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(iconutil.terminationStatus)")
}

print("Generated \(icnsURL.path)")
