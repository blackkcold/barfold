import XCTest
@testable import BarFoldProtocol

final class MenuBarLayoutLogicTests: XCTestCase {
    private func item(
        _ id: String,
        width: Double = 24,
        kind: MenuBarItemKind = .app,
        observed: MenuBarItemGroup? = .hidden,
        x: Double = 100
    ) -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(
            id: id,
            bundleID: id,
            appName: id,
            kind: kind,
            x: x,
            width: width,
            observedGroup: observed
        )
    }

    // MARK: - Capacity

    func testCapacityIsOKWhenThereIsRoom() {
        let capacity = MenuBarCapacityCalculator.evaluate(
            items: [item("a", observed: .visible), item("cc", kind: .system, observed: .visible)],
            arrowWidth: 26,
            menuBarWidth: 1920
        )
        XCTAssertEqual(capacity.level, .ok)
        XCTAssertEqual(capacity.usedWidth, 74)
        XCTAssertTrue(capacity.fits)
    }

    func testCapacityIsTightInsideTheReserve() {
        let capacity = MenuBarCapacityCalculator.evaluate(
            items: [item("a", width: 1800, observed: .visible)],
            arrowWidth: 26,
            menuBarWidth: 1920
        )
        XCTAssertEqual(capacity.level, .tight)
        XCTAssertTrue(capacity.fits)
    }

    func testCapacityOverflows() {
        let capacity = MenuBarCapacityCalculator.evaluate(
            items: [item("a", width: 2000, observed: .visible)],
            arrowWidth: 26,
            menuBarWidth: 1920
        )
        XCTAssertEqual(capacity.level, .overflow)
        XCTAssertFalse(capacity.fits)
        XCTAssertEqual(capacity.available, 0)
    }

    func testCapacityIgnoresHiddenGroup() {
        let capacity = MenuBarCapacityCalculator.evaluate(
            items: [
                item("hidden", width: 500, observed: .hidden),
                item("visible", width: 100, observed: .visible),
            ],
            arrowWidth: 26,
            menuBarWidth: 1920
        )
        XCTAssertEqual(capacity.usedWidth, 126)
    }

    // MARK: - Undo

    func testUndoStackPushesAndPopsInOrder() {
        var stack = MenuBarUndoStack()
        let first = MenuBarUndoEntry(layout: MenuBarLayout(order: ["a"]), ids: ["a"])
        let second = MenuBarUndoEntry(layout: MenuBarLayout(order: ["b"]), ids: ["b"])
        stack.push(first)
        stack.push(second)
        XCTAssertEqual(stack.pop(), second)
        XCTAssertEqual(stack.pop(), first)
        XCTAssertFalse(stack.canUndo)
    }

    func testUndoStackRespectsLimit() {
        var stack = MenuBarUndoStack(limit: 2)
        stack.push(MenuBarUndoEntry(layout: MenuBarLayout(order: ["a"]), ids: ["a"]))
        stack.push(MenuBarUndoEntry(layout: MenuBarLayout(order: ["b"]), ids: ["b"]))
        stack.push(MenuBarUndoEntry(layout: MenuBarLayout(order: ["c"]), ids: ["c"]))
        XCTAssertEqual(stack.entries.map(\.ids), [["b"], ["c"]])
    }

    func testUndoPlannerAnchorsEachItemBeforeItsOldNeighbour() {
        let layout = MenuBarLayout(
            order: ["a", "b", "c"],
            groups: ["a": .hidden, "b": .hidden, "c": .hidden]
        )
        let steps = MenuBarUndoPlanner.plan(entry: MenuBarUndoEntry(layout: layout, ids: ["b"]))
        XCTAssertEqual(steps, [MenuBarBatchStep(id: "b", group: .hidden, before: "c")])
    }

    func testUndoPlannerUsesIndexWhenItWasLastInGroup() {
        let layout = MenuBarLayout(
            order: ["a", "b"],
            groups: ["a": .visible, "b": .visible]
        )
        let steps = MenuBarUndoPlanner.plan(entry: MenuBarUndoEntry(layout: layout, ids: ["b"]))
        XCTAssertEqual(steps.first?.before, nil)
        XCTAssertEqual(steps.first?.index, 1)
    }

    // MARK: - New item detection

    func testDetectorSeedsWithoutReportingExistingItems() {
        var detector = MenuBarNewItemDetector()
        let fresh = detector.observe([item("a"), item("b")])
        XCTAssertTrue(fresh.isEmpty)
        XCTAssertTrue(detector.isSeeded)
    }

    func testDetectorReportsOnlyNewManagedItems() {
        var detector = MenuBarNewItemDetector()
        _ = detector.observe([item("a")])
        let fresh = detector.observe([
            item("a"),
            item("new", x: 50),
            item("cc", kind: .system, observed: .visible),
        ])
        XCTAssertEqual(fresh.map(\.id), ["new"])
    }

    func testDetectorReportsNewItemsLeftToRight() {
        var detector = MenuBarNewItemDetector()
        _ = detector.observe([item("a")])
        let fresh = detector.observe([
            item("a"),
            item("right", x: 300),
            item("left", x: 10),
        ])
        XCTAssertEqual(fresh.map(\.id), ["left", "right"])
    }

    func testDetectorTreatsReappearingItemAsNew() {
        var detector = MenuBarNewItemDetector()
        _ = detector.observe([item("a")])
        _ = detector.observe([])
        let fresh = detector.observe([item("a")])
        XCTAssertEqual(fresh.map(\.id), ["a"])
    }
}
