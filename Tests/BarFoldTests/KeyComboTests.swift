import XCTest
@testable import BarFoldProtocol

final class KeyComboTests: XCTestCase {
    func testParseCompactDefault() {
        let combo = KeyCombo.parse("⌃⌥H")
        XCTAssertEqual(combo?.keyCode, 4)
        XCTAssertEqual(combo?.modifiers, KeyCombo.controlModifier | KeyCombo.optionModifier)
        XCTAssertEqual(combo?.displayString, "⌃⌥H")
    }

    func testParseTokenForm() {
        let combo = KeyCombo.parse("ctrl+alt+j")
        XCTAssertEqual(combo?.keyCode, 38)
        XCTAssertEqual(combo?.displayString, "⌃⌥J")
    }

    func testParseCommandShift() {
        let combo = KeyCombo.parse("cmd+shift+p")
        XCTAssertEqual(combo?.keyCode, 35)
        XCTAssertEqual(combo?.displayString, "⇧⌘P")
    }

    func testBareKeyIsRejected() {
        XCTAssertNil(KeyCombo.parse("H"))
        XCTAssertNil(KeyCombo.parse("⌥"))
    }

    func testUnknownKeyIsRejected() {
        XCTAssertNil(KeyCombo.parse("ctrl+alt+not-a-key"))
    }

    func testDefaultComboIsValid() {
        XCTAssertTrue(KeyCombo.defaultCombo.isValid)
        XCTAssertEqual(KeyCombo.defaultCombo.displayString, "⌃⌥H")
    }
}
