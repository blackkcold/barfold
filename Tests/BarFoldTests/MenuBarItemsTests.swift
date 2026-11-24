import XCTest
@testable import BarFoldProtocol

final class MenuBarItemsTests: XCTestCase {
    private func item(
        _ bundleID: String,
        id: String? = nil,
        ordinal: Int = 0,
        x: Double = 0,
        kind: MenuBarItemKind = .app,
        observed: MenuBarItemGroup? = nil,
        group: MenuBarItemGroup = .hidden
    ) -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(
            id: id ?? MenuBarItemIdentity.make(bundleID: bundleID, identifier: nil, ordinal: ordinal),
            bundleID: bundleID,
            appName: bundleID,
            kind: kind,
            x: x,
            width: 24,
            observedGroup: observed,
            group: group
        )
    }

    // MARK: - Identity

    func testIdentityPrefersAccessibilityIdentifier() {
        let id = MenuBarItemIdentity.make(bundleID: "com.apple.controlcenter", identifier: "com.apple.menuextra.wifi", ordinal: 3)
        XCTAssertEqual(id, "com.apple.controlcenter::id:com.apple.menuextra.wifi")
        XCTAssertEqual(MenuBarItemIdentity.bundleID(of: id), "com.apple.controlcenter")
        XCTAssertFalse(MenuBarItemIdentity.isOrdinalID(id))
    }

    func testIdentityFallsBackToOrdinal() {
        let id = MenuBarItemIdentity.make(bundleID: "com.tencent.xinWeChat", identifier: "  ", ordinal: 1)
        XCTAssertEqual(id, "com.tencent.xinWeChat::n:1")
        XCTAssertTrue(MenuBarItemIdentity.isOrdinalID(id))
        XCTAssertEqual(MenuBarItemIdentity.bundleID(of: id), "com.tencent.xinWeChat")
    }

    func testIdentitySanitizesMultiLineIdentifiers() {
        let id = MenuBarItemIdentity.make(
            bundleID: "com.microsoft.OneDrive",
            identifier: "OneDrive — 个人\n已备份和同步",
            ordinal: 0
        )
        XCTAssertFalse(id.contains("\n"))
        XCTAssertEqual(id, "com.microsoft.OneDrive::id:OneDrive — 个人 已备份和同步")
    }

    func testIdentityKeepsOrdinalsApartForMultipleInstancesOfOneBundle() {
        let first = MenuBarItemIdentity.make(bundleID: "com.microsoft.OneDrive", identifier: nil, ordinal: 0)
        let second = MenuBarItemIdentity.make(bundleID: "com.microsoft.OneDrive", identifier: nil, ordinal: 1)
        XCTAssertNotEqual(first, second)
    }

    // MARK: - Geometry classification

    func testClassifyUsesArrowLeftEdge() {
        XCTAssertEqual(MenuBarItemIdentity.classify(x: 1500, arrowMinX: 1525), .hidden)
        XCTAssertEqual(MenuBarItemIdentity.classify(x: 1526, arrowMinX: 1525), .visible)
        // Items flush against the arrow belong to the visible side: they sit to
        // its right and survive a collapse.
        XCTAssertEqual(MenuBarItemIdentity.classify(x: 1525, arrowMinX: 1525), .visible)
    }

    // MARK: - Multi-display coordinates

    private let primary = Rect(x: 0, y: 0, width: 1920, height: 1080)
    private let secondary = Rect(x: 1920, y: -64, width: 1470, height: 956)

    func testRelativeXIsIdentityOnASingleDisplay() {
        XCTAssertEqual(MenuBarCoordinates.relativeX(1500, screens: [primary]), 1500)
        XCTAssertEqual(MenuBarCoordinates.relativeX(-1453, screens: [primary]), -1453)
    }

    func testRelativeXMapsEachDisplayToItsOwnOrigin() {
        XCTAssertEqual(MenuBarCoordinates.relativeX(1600, screens: [primary, secondary]), 1600)
        XCTAssertEqual(MenuBarCoordinates.relativeX(3118, screens: [primary, secondary]), 1198)
    }

    func testRelativeXKeepsOffscreenItemsLeftOfTheLeftmostDisplay() {
        // The separator pushes items past the left edge of every display.
        XCTAssertEqual(MenuBarCoordinates.relativeX(-1453, screens: [primary, secondary]), -1453)
    }

    func testMirroredBarsClassifyConsistently() {
        // Arrow on the secondary display at global x 3093 → relative 1173.
        let arrow = MenuBarCoordinates.relativeX(3093, screens: [primary, secondary])
        // The same logical item is drawn at relative 1198 on either display.
        XCTAssertEqual(MenuBarItemIdentity.classify(
            x: MenuBarCoordinates.relativeX(3118, screens: [primary, secondary]),
            arrowMinX: arrow
        ), .visible)
        XCTAssertEqual(MenuBarItemIdentity.classify(
            x: MenuBarCoordinates.relativeX(1198, screens: [primary, secondary]),
            arrowMinX: arrow
        ), .visible)
        // An item left of the arrow is hidden on whichever display it is drawn.
        XCTAssertEqual(MenuBarItemIdentity.classify(
            x: MenuBarCoordinates.relativeX(2920, screens: [primary, secondary]),
            arrowMinX: arrow
        ), .hidden)
        XCTAssertEqual(MenuBarItemIdentity.classify(
            x: MenuBarCoordinates.relativeX(1000, screens: [primary, secondary]),
            arrowMinX: arrow
        ), .hidden)
    }

    // MARK: - Layout

    func testNewItemDefaultsToHiddenAtTheLeftEnd() {
        let layout = MenuBarLayout(order: ["a::n:0"], groups: ["a::n:0": .visible])
        let hiddenNew = MenuBarLayout().arrange(live: [
            item("a", id: "a::n:0", x: 100),
            item("b", id: "b::n:0", x: 50),
        ])[.hidden]
        XCTAssertNil(layout.group(for: "b::n:0"))
        XCTAssertEqual(hiddenNew, ["b::n:0", "a::n:0"])
    }

    func testArrangeKeepsStoredGroupOrderAndDropsMissingItems() {
        let layout = MenuBarLayout(
            order: ["a::n:0", "b::n:0", "c::n:0"],
            groups: ["a::n:0": .hidden, "b::n:0": .visible, "c::n:0": .hidden]
        )
        let arrangement = layout.arrange(live: [
            item("a", id: "a::n:0", x: 10),
            item("b", id: "b::n:0", x: 20),
        ])
        XCTAssertEqual(arrangement[.visible], ["b::n:0"])
        XCTAssertEqual(arrangement[.hidden], ["a::n:0"])
    }

    func testSetGroupMovesItemToEndOfTargetGroup() {
        var layout = MenuBarLayout(
            order: ["a::n:0", "b::n:0", "c::n:0"],
            groups: ["a::n:0": .hidden, "b::n:0": .hidden, "c::n:0": .hidden]
        )
        layout.setGroup(.visible, for: "b::n:0")
        XCTAssertEqual(layout.members(of: .visible), ["b::n:0"])
        XCTAssertEqual(layout.members(of: .hidden), ["a::n:0", "c::n:0"])
    }

    func testMoveClampsIndexWithinGroup() {
        var layout = MenuBarLayout(
            order: ["a::n:0", "b::n:0", "c::n:0"],
            groups: ["a::n:0": .visible, "b::n:0": .visible, "c::n:0": .visible]
        )
        layout.move("c::n:0", to: 99, in: .visible)
        XCTAssertEqual(layout.members(of: .visible), ["a::n:0", "b::n:0", "c::n:0"])
        layout.move("c::n:0", to: -3, in: .visible)
        XCTAssertEqual(layout.members(of: .visible), ["c::n:0", "a::n:0", "b::n:0"])
    }

    func testMoveAcrossGroupInsertsAtRequestedIndex() {
        var layout = MenuBarLayout(
            order: ["a::n:0", "b::n:0", "c::n:0"],
            groups: ["a::n:0": .hidden, "b::n:0": .hidden, "c::n:0": .hidden]
        )
        layout.move("c::n:0", to: 1, in: .visible)
        XCTAssertEqual(layout.members(of: .visible), ["c::n:0"])
        XCTAssertEqual(layout.members(of: .hidden), ["a::n:0", "b::n:0"])

        var second = layout
        second.move("a::n:0", to: 0, in: .visible)
        XCTAssertEqual(second.members(of: .visible), ["a::n:0", "c::n:0"])
    }

    func testAdoptMirrorsBarOrderAndPrunesStaleIds() {
        var layout = MenuBarLayout(
            order: ["a::n:0", "b::n:0"],
            groups: ["a::n:0": .visible, "b::n:0": .hidden]
        )
        layout.adopt(liveIDs: ["b::n:0", "c::n:0"])
        XCTAssertEqual(layout.order, ["b::n:0", "c::n:0"])
        XCTAssertEqual(layout.group(for: "b::n:0"), .hidden)
        XCTAssertNil(layout.group(for: "a::n:0"))
    }

    func testSnapshotPruneKeepsOnlyLiveIds() {
        var layout = MenuBarLayout(order: ["a::n:0", "b::n:0"], groups: ["a::n:0": .visible, "b::n:0": .hidden])
        layout.prune(keeping: ["b::n:0"])
        XCTAssertEqual(layout.order, ["b::n:0"])
        XCTAssertEqual(layout.groups.count, 1)
    }

    func testIncompatibleVersionIsRejected() {
        let future = MenuBarLayout(version: MenuBarLayout.currentVersion + 1)
        XCTAssertFalse(future.isCompatible)
        XCTAssertTrue(MenuBarLayout().isCompatible)
    }

    // MARK: - Drag geometry

    private let arrow = Rect(x: 1620, y: 0, width: 28, height: 24)
    private let separator = Rect(x: 1606, y: 0, width: 9, height: 24)

    func testDragPlanStartsAtItemCenter() {
        let target = item("m", id: "m::n:0", x: 900)
        let plan = MenuBarDragGeometry.plan(
            item: target, to: .hidden, index: 0,
            items: [target], arrow: arrow, separator: separator
        )
        XCTAssertEqual(plan.source.x, 912)
        XCTAssertEqual(plan.source.y, 12)
    }

    func testDragPlanPlacesItemRightOfTheArrowForVisibleIndexZero() {
        let target = item("m", id: "m::n:0", x: 900)
        let plan = MenuBarDragGeometry.plan(
            item: target, to: .visible, index: 0,
            items: [target, item("a", id: "a::n:0", x: 1660, group: .visible), item("b", id: "b::n:0", x: 1700, group: .visible)],
            arrow: arrow, separator: separator
        )
        XCTAssertEqual(plan.destination.x, 1654)
        XCTAssertEqual(plan.expectedGroup, .visible)
        XCTAssertEqual(plan.expectedIndex, 0)
    }

    func testDragPlanAppendsAfterLastVisibleItem() {
        let target = item("m", id: "m::n:0", x: 900)
        let plan = MenuBarDragGeometry.plan(
            item: target, to: .visible, index: 99,
            items: [target, item("a", id: "a::n:0", x: 1660, group: .visible), item("b", id: "b::n:0", x: 1700, group: .visible)],
            arrow: arrow, separator: separator
        )
        XCTAssertEqual(plan.destination.x, 1730)
        XCTAssertEqual(plan.expectedIndex, 2)
    }

    func testDragPlanInsertsBeforeTheTargetVisibleItem() {
        let target = item("m", id: "m::n:0", x: 900)
        let plan = MenuBarDragGeometry.plan(
            item: target, to: .visible, index: 1,
            items: [target, item("a", id: "a::n:0", x: 1660, group: .visible), item("b", id: "b::n:0", x: 1700, group: .visible)],
            arrow: arrow, separator: separator
        )
        XCTAssertEqual(plan.destination.x, 1702)
    }

    func testDragPlanUsesTheSeparatorForTheHiddenEdge() {
        let target = item("m", id: "m::n:0", x: 900)
        let plan = MenuBarDragGeometry.plan(
            item: target, to: .hidden, index: 0,
            items: [target], arrow: arrow, separator: separator
        )
        XCTAssertEqual(plan.destination.x, 1600)
    }

    func testDragPlanPrefixesTheLeftmostHiddenItem() {
        let target = item("m", id: "m::n:0", x: 900)
        let plan = MenuBarDragGeometry.plan(
            item: target, to: .hidden, index: 0,
            items: [target, item("c", id: "c::n:0", x: 100), item("d", id: "d::n:0", x: 150)],
            arrow: arrow, separator: separator
        )
        XCTAssertEqual(plan.destination.x, 94)
    }

    func testDragPlanIgnoresSystemItemsWhenChoosingAnchors() {
        let target = item("m", id: "m::n:0", x: 900)
        let system = item("cc", id: "cc::id:clock", x: 1700, kind: .system, observed: .visible)
        let plan = MenuBarDragGeometry.plan(
            item: target, to: .visible, index: 0,
            items: [target, system], arrow: arrow, separator: separator
        )
        XCTAssertEqual(plan.destination.x, 1654)
    }

    // MARK: - Batch planning

    func testBatchAtVisibleFrontEdgeInsertsInReverse() {
        let live = [
            item("a", id: "a", x: 100),
            item("b", id: "b", x: 200),
            item("c", id: "c", x: 300),
        ]
        let steps = MenuBarBatchPlanner.plan(ids: ["c", "a", "b"], group: .visible, before: nil, live: live)
        XCTAssertEqual(steps.map(\.id), ["c", "b", "a"])
        XCTAssertTrue(steps.allSatisfy { $0.before == nil })
    }

    func testBatchAtHiddenBackEdgeInsertsInForwardOrder() {
        let live = [
            item("a", id: "a", x: 100),
            item("b", id: "b", x: 200),
        ]
        let steps = MenuBarBatchPlanner.plan(ids: ["b", "a"], group: .hidden, before: nil, live: live)
        XCTAssertEqual(steps.map(\.id), ["a", "b"])
    }

    func testBatchBeforeAnchorKeepsSelectionOrderWithOneAnchor() {
        let live = [
            item("a", id: "a", x: 100),
            item("b", id: "b", x: 200),
            item("anchor", id: "anchor", x: 300),
        ]
        let steps = MenuBarBatchPlanner.plan(ids: ["b", "a"], group: .visible, before: "anchor", live: live)
        XCTAssertEqual(steps.map(\.id), ["a", "b"])
        XCTAssertTrue(steps.allSatisfy { $0.before == "anchor" })
    }

    func testBatchIgnoresSystemAndUnknownItems() {
        let live = [
            item("a", id: "a", x: 100),
            item("cc", id: "cc", x: 900, kind: .system),
        ]
        let steps = MenuBarBatchPlanner.plan(ids: ["a", "cc", "missing"], group: .hidden, before: nil, live: live)
        XCTAssertEqual(steps.map(\.id), ["a"])
    }

    func testBatchWithNoManagedSelectionIsEmpty() {
        let live = [item("cc", id: "cc", x: 900, kind: .system)]
        XCTAssertTrue(MenuBarBatchPlanner.plan(ids: ["cc"], group: .hidden, before: nil, live: live).isEmpty)
    }

    // MARK: - Report

    func testReportAppliesGroupsAndIndices() {
        let layout = MenuBarLayout(
            order: ["a::n:0", "b::n:0"],
            groups: ["a::n:0": .visible, "b::n:0": .visible]
        )
        let live = [
            item("a", id: "a::n:0", x: 100),
            item("b", id: "b::n:0", x: 200),
            item("com.apple.controlcenter", id: "cc::id:clock", x: 900, kind: .system, observed: .visible),
        ]
        let report = MenuBarItemReport.apply(layout: layout, live: live)
        XCTAssertEqual(report[0].group, .visible)
        XCTAssertEqual(report[0].index, 0)
        XCTAssertEqual(report[1].index, 1)
        // System extras are never re-grouped; they keep what geometry says.
        XCTAssertEqual(report[2].group, .visible)
    }

    func testReportTreatsUnknownItemsAsHiddenButKeepsObservedGeometry() {
        let live = [item("x", id: "x::n:0", x: 5, observed: .hidden)]
        let report = MenuBarItemReport.apply(layout: MenuBarLayout(), live: live)
        XCTAssertEqual(report[0].group, .hidden)
        XCTAssertEqual(report[0].observedGroup, .hidden)
    }
}
