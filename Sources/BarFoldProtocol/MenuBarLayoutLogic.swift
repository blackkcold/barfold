import Foundation

/// How much of the menu bar the visible group may consume before macOS starts
/// pushing system icons off-screen.
///
/// Widths come from the accessibility scan, which reports content width rather
/// than the window width; that under-counts a little, so the reserve absorbs it.
public struct MenuBarCapacity: Codable, Sendable, Equatable {
    public enum Level: String, Codable, Sendable {
        case ok
        case tight
        case overflow
    }

    public var menuBarWidth: Double
    public var usedWidth: Double
    public var reserve: Double
    public var level: Level

    public var available: Double {
        max(0, menuBarWidth - reserve - usedWidth)
    }

    public var fits: Bool { level != .overflow }

    public init(menuBarWidth: Double, usedWidth: Double, reserve: Double, level: Level) {
        self.menuBarWidth = menuBarWidth
        self.usedWidth = usedWidth
        self.reserve = reserve
        self.level = level
    }

    public func json() -> JSONValue {
        .object([
            "menuBarWidth": .number((menuBarWidth * 10).rounded() / 10),
            "usedWidth": .number((usedWidth * 10).rounded() / 10),
            "available": .number((available * 10).rounded() / 10),
            "reserve": .number(reserve),
            "level": .string(level.rawValue),
            "fits": .bool(fits),
        ])
    }
}

public enum MenuBarCapacityCalculator {
    /// Keeps a margin so the arrow never ends up under the notch or at the very
    /// edge, and so a single wide icon cannot starve the system extras.
    public static let defaultReserve: Double = 120

    public static func evaluate(
        items: [MenuBarItemSnapshot],
        arrowWidth: Double,
        menuBarWidth: Double,
        reserve: Double = defaultReserve
    ) -> MenuBarCapacity {
        let system = items
            .filter { $0.kind == .system }
            .reduce(0) { $0 + $1.width }
        let visible = items
            .filter { $0.isManaged && ($0.observedGroup ?? .hidden) == .visible }
            .reduce(0) { $0 + $1.width }
        let used = system + visible + arrowWidth
        let level: MenuBarCapacity.Level
        if used + reserve <= menuBarWidth {
            level = .ok
        } else if used <= menuBarWidth {
            level = .tight
        } else {
            level = .overflow
        }
        return MenuBarCapacity(
            menuBarWidth: menuBarWidth,
            usedWidth: used,
            reserve: reserve,
            level: level
        )
    }
}

/// One undoable operation: the layout before it ran, plus the items it touched.
///
/// Undo only replays the affected items. Rebuilding the entire bar would move
/// dozens of icons for a one-icon mistake, and every extra move is another chance
/// to land somewhere unexpected.
public struct MenuBarUndoEntry: Sendable, Equatable {
    public var layout: MenuBarLayout
    public var ids: [String]

    public init(layout: MenuBarLayout, ids: [String]) {
        self.layout = layout
        self.ids = ids
    }
}

/// Turns an undo entry into insertions that put each item back before the
/// neighbour it had.
public enum MenuBarUndoPlanner {
    public static func plan(entry: MenuBarUndoEntry) -> [MenuBarBatchStep] {
        var steps: [MenuBarBatchStep] = []
        for id in entry.ids.reversed() {
            let group = entry.layout.group(for: id) ?? .hidden
            let members = entry.layout.members(of: group)
            if let position = members.firstIndex(of: id), position + 1 < members.count {
                steps.append(MenuBarBatchStep(id: id, group: group, before: members[position + 1]))
            } else {
                steps.append(MenuBarBatchStep(
                    id: id,
                    group: group,
                    before: nil,
                    index: members.firstIndex(of: id) ?? 0
                ))
            }
        }
        return steps
    }
}

/// Bounded history of undoable operations.
public struct MenuBarUndoStack: Sendable, Equatable {
    public private(set) var entries: [MenuBarUndoEntry]
    public let limit: Int

    public init(limit: Int = 20) {
        self.limit = max(1, limit)
        self.entries = []
    }

    public var canUndo: Bool { !entries.isEmpty }
    public var last: MenuBarUndoEntry? { entries.last }

    public mutating func push(_ entry: MenuBarUndoEntry) {
        entries.append(entry)
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
    }

    public mutating func pop() -> MenuBarUndoEntry? {
        entries.popLast()
    }

    public mutating func removeAll() {
        entries.removeAll()
    }
}

/// Detects menu bar extras that appeared after BarFold started watching.
///
/// The first observation only seeds the baseline: nothing that was already there
/// may be treated as new, or every launch would move the user's icons again.
public struct MenuBarNewItemDetector: Sendable, Equatable {
    private var known: Set<String> = []
    private var seeded = false

    public init() {}

    public var isSeeded: Bool { seeded }

    public mutating func observe(_ items: [MenuBarItemSnapshot]) -> [MenuBarItemSnapshot] {
        let managed = items.filter(\.isManaged)
        let liveIDs = Set(managed.map(\.id))
        guard seeded else {
            known = liveIDs
            seeded = true
            return []
        }
        let fresh = managed
            .filter { !known.contains($0.id) }
            .sorted { $0.x < $1.x }
        known = liveIDs
        return fresh
    }

    /// Forgets an id so a later reappearance counts as new again. Used when the
    /// user explicitly dismisses a hint.
    public mutating func forget(_ id: String) {
        known.remove(id)
    }
}
