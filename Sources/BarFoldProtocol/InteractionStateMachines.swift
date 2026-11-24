import Foundation

/// Pure, clock-injected decisions for the two interaction timers. Keeping them
/// out of AppKit makes the edge cases testable without a GUI.
public struct HoverStateMachine: Sendable {
    public private(set) var beganAt: Date?

    public init() {}

    public mutating func reset() {
        beganAt = nil
    }

    /// Returns true exactly once, when the pointer has stayed in an empty part
    /// of the menu bar for `delay` seconds.
    public mutating func update(
        inMenuBar: Bool,
        overItem: Bool,
        now: Date,
        delay: TimeInterval
    ) -> Bool {
        guard inMenuBar, !overItem else {
            beganAt = nil
            return false
        }
        if let beganAt {
            if now.timeIntervalSince(beganAt) >= delay {
                self.beganAt = nil
                return true
            }
            return false
        }
        beganAt = now
        return false
    }
}

public struct AutoCollapseStateMachine: Sendable {
    public private(set) var outsideSince: Date?

    public init() {}

    public mutating func reset() {
        outsideSince = nil
    }

    /// Returns true exactly once, when the pointer has been outside the menu
    /// bar (and no menu is open) for `delay` seconds.
    public mutating func update(
        inMenuBar: Bool,
        menuOpen: Bool,
        now: Date,
        delay: TimeInterval
    ) -> Bool {
        guard !inMenuBar, !menuOpen else {
            outsideSince = nil
            return false
        }
        if let outsideSince {
            if now.timeIntervalSince(outsideSince) >= delay {
                self.outsideSince = nil
                return true
            }
            return false
        }
        outsideSince = now
        return false
    }
}
