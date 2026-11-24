import XCTest
@testable import BarFoldProtocol

final class InteractionStateMachineTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testHoverTriggersOnceAfterDelay() {
        var machine = HoverStateMachine()
        XCTAssertFalse(machine.update(inMenuBar: true, overItem: false, now: start, delay: 0.25))
        XCTAssertFalse(machine.update(inMenuBar: true, overItem: false,
                                      now: start.addingTimeInterval(0.2), delay: 0.25))
        XCTAssertTrue(machine.update(inMenuBar: true, overItem: false,
                                     now: start.addingTimeInterval(0.3), delay: 0.25))
        XCTAssertFalse(machine.update(inMenuBar: true, overItem: false,
                                      now: start.addingTimeInterval(0.4), delay: 0.25))
    }

    func testHoverResetsOverAnItem() {
        var machine = HoverStateMachine()
        XCTAssertFalse(machine.update(inMenuBar: true, overItem: false, now: start, delay: 0.25))
        XCTAssertFalse(machine.update(inMenuBar: true, overItem: true,
                                      now: start.addingTimeInterval(0.2), delay: 0.25))
        XCTAssertFalse(machine.update(inMenuBar: true, overItem: false,
                                      now: start.addingTimeInterval(0.3), delay: 0.25))
    }

    func testHoverResetsWhenLeavingMenuBar() {
        var machine = HoverStateMachine()
        XCTAssertFalse(machine.update(inMenuBar: true, overItem: false, now: start, delay: 0.25))
        XCTAssertFalse(machine.update(inMenuBar: false, overItem: false,
                                      now: start.addingTimeInterval(0.2), delay: 0.25))
        XCTAssertFalse(machine.update(inMenuBar: true, overItem: false,
                                      now: start.addingTimeInterval(0.3), delay: 0.25))
    }

    func testAutoCollapseWaitsForDelay() {
        var machine = AutoCollapseStateMachine()
        XCTAssertFalse(machine.update(inMenuBar: false, menuOpen: false, now: start, delay: 0.6))
        XCTAssertFalse(machine.update(inMenuBar: false, menuOpen: false,
                                      now: start.addingTimeInterval(0.5), delay: 0.6))
        XCTAssertTrue(machine.update(inMenuBar: false, menuOpen: false,
                                     now: start.addingTimeInterval(0.7), delay: 0.6))
    }

    func testAutoCollapsePausedByOpenMenu() {
        var machine = AutoCollapseStateMachine()
        XCTAssertFalse(machine.update(inMenuBar: false, menuOpen: false, now: start, delay: 0.6))
        XCTAssertFalse(machine.update(inMenuBar: false, menuOpen: true,
                                      now: start.addingTimeInterval(0.5), delay: 0.6))
        XCTAssertFalse(machine.update(inMenuBar: false, menuOpen: false,
                                      now: start.addingTimeInterval(0.7), delay: 0.6))
    }

    func testAutoCollapseResetsWhenPointerReturns() {
        var machine = AutoCollapseStateMachine()
        XCTAssertFalse(machine.update(inMenuBar: false, menuOpen: false, now: start, delay: 0.6))
        XCTAssertFalse(machine.update(inMenuBar: true, menuOpen: false,
                                      now: start.addingTimeInterval(0.3), delay: 0.6))
        XCTAssertFalse(machine.update(inMenuBar: false, menuOpen: false,
                                      now: start.addingTimeInterval(0.5), delay: 0.6))
        XCTAssertTrue(machine.update(inMenuBar: false, menuOpen: false,
                                     now: start.addingTimeInterval(1.2), delay: 0.6))
    }
}
