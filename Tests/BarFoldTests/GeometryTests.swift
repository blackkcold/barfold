import XCTest
@testable import BarFoldProtocol

final class GeometryTests: XCTestCase {
    private let external = ScreenDescriptor(
        name: "External",
        frame: Rect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: Rect(x: 0, y: 83, width: 1920, height: 967),
        safeAreaTop: 0,
        isMain: true,
        backingScale: 2
    )

    private let notched = ScreenDescriptor(
        name: "Built-in",
        frame: Rect(x: 1920, y: -64, width: 1470, height: 956),
        visibleFrame: Rect(x: 1920, y: -64, width: 1470, height: 923),
        safeAreaTop: 32,
        isMain: false,
        backingScale: 2
    )

    func testMenuBarBandOnExternalDisplay() {
        let band = MenuBarGeometry.menuBarBand(for: external, systemThickness: 22)
        XCTAssertEqual(band.height, 30)
        XCTAssertEqual(band.y, 1050)
        XCTAssertEqual(band.width, 1920)
    }

    func testMenuBarBandOnNotchedDisplay() {
        let band = MenuBarGeometry.menuBarBand(for: notched, systemThickness: 22)
        XCTAssertEqual(band.height, 33)
        XCTAssertEqual(band.y, 859)
        XCTAssertEqual(band.width, 1470)
    }

    func testPointInsideMenuBar() {
        XCTAssertTrue(MenuBarGeometry.isInMenuBar(
            point: Point(x: 100, y: 1060),
            screens: [external, notched],
            systemThickness: 22
        ))
    }

    func testPointOutsideMenuBar() {
        XCTAssertFalse(MenuBarGeometry.isInMenuBar(
            point: Point(x: 100, y: 1040),
            screens: [external, notched],
            systemThickness: 22
        ))
    }

    func testCollapsedLengthUsesWidestScreen() {
        let length = MenuBarGeometry.collapsedLength(for: [external, notched])
        XCTAssertEqual(length, 3840)
    }

    func testCoreGraphicsRectConversion() {
        let converted = MenuBarGeometry.appKitRect(
            fromCoreGraphics: Rect(x: 100, y: 0, width: 50, height: 30),
            mainScreenHeight: 1080
        )
        XCTAssertEqual(converted.y, 1050)
        XCTAssertEqual(converted.x, 100)
    }

    func testRectIntersection() {
        XCTAssertTrue(Rect(x: 0, y: 0, width: 10, height: 10)
            .intersects(Rect(x: 5, y: 5, width: 10, height: 10)))
        XCTAssertFalse(Rect(x: 0, y: 0, width: 10, height: 10)
            .intersects(Rect(x: 20, y: 20, width: 10, height: 10)))
    }
}
