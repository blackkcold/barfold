import Foundation

/// Which side of BarFold's divider a menu bar item belongs to.
///
/// BarFold's engine hides everything left of the separator when it collapses, so
/// the group is not cosmetic: `visible` means "sits right of the arrow and stays
/// on screen while collapsed", `hidden` means "sits left of the separator".
public enum MenuBarItemGroup: String, Codable, Sendable, CaseIterable {
    case visible
    case hidden

    public var displayName: String {
        switch self {
        case .visible: return "收起时仍显示"
        case .hidden: return "收起时隐藏"
        }
    }
}

/// How an item participates in the layout. Only `.app` items are ever moved by
/// BarFold; system extras are owned by macOS and BarFold's own items are anchors.
public enum MenuBarItemKind: String, Codable, Sendable {
    case app
    case system
    case barfold
}

/// A menu bar extra as observed through the Accessibility API.
///
/// `id` is the only stable handle the layout store keeps. Everything else is
/// display data and may change between launches (badge counts, localized names).
public struct MenuBarItemSnapshot: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var bundleID: String
    public var appName: String
    public var title: String
    public var detail: String
    public var kind: MenuBarItemKind
    /// Screen x of the item's left edge, in global top-left coordinates.
    public var x: Double
    /// Screen y of the item's top edge, in global top-left coordinates.
    public var y: Double
    public var width: Double
    /// Group derived from the separator's geometry. Only meaningful while collapsed.
    public var observedGroup: MenuBarItemGroup?
    /// Group after merging the stored layout. System and anchor items are never
    /// re-grouped, so they report their observed group.
    public var group: MenuBarItemGroup
    /// Position within `group`, left to right, starting at 0.
    public var index: Int

    public var isManaged: Bool { kind == .app }

    public init(
        id: String,
        bundleID: String,
        appName: String,
        title: String = "",
        detail: String = "",
        kind: MenuBarItemKind,
        x: Double,
        y: Double = 0,
        width: Double,
        observedGroup: MenuBarItemGroup? = nil,
        group: MenuBarItemGroup = .hidden,
        index: Int = 0
    ) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.detail = detail
        self.kind = kind
        self.x = x
        self.y = y
        self.width = width
        self.observedGroup = observedGroup
        self.group = group
        self.index = index
    }

    public var displayName: String {
        if !appName.isEmpty { return appName }
        if !detail.isEmpty { return detail }
        if !title.isEmpty { return title }
        return bundleID
    }
}

/// Stable identity rules for menu bar extras.
///
/// macOS gives each extra an accessibility identifier only sometimes
/// (`com.apple.menuextra.wifi` for system items, rarely for third-party apps).
/// When it is missing we fall back to the item's ordinal within its bundle,
/// counted left to right. That survives relaunches but not a user reordering the
/// bar while BarFold is not looking, which is why the catalog re-scans on demand.
public enum MenuBarItemIdentity {
    public static let separator = "::"

    public static func make(bundleID: String, identifier: String?, ordinal: Int) -> String {
        let trimmed = sanitize(identifier ?? "")
        if !trimmed.isEmpty {
            return "\(bundleID)\(separator)id:\(trimmed)"
        }
        return "\(bundleID)\(separator)n:\(ordinal)"
    }

    /// Accessibility identifiers are not always clean: OneDrive returns a
    /// multi-line title complete with a newline. Collapsing whitespace keeps ids
    /// printable in a shell and valid as JSON object keys.
    public static func sanitize(_ raw: String) -> String {
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(collapsed.prefix(64))
    }

    public static func bundleID(of id: String) -> String? {
        id.components(separatedBy: separator).first
    }

    /// Whether `id` is an ordinal-based fallback rather than an accessibility
    /// identifier. Fallback ids are the ones that can shift when an app restarts.
    public static func isOrdinalID(_ id: String) -> Bool {
        id.contains("\(separator)n:")
    }

    /// Observed group from geometry: everything left of the arrow belongs to the
    /// hidden side, everything right of it stays visible while collapsed.
    ///
    /// The arrow's left edge is the only stable boundary. The separator's frame is
    /// useless here: it spans every display, so its right edge sits far off-screen.
    public static func classify(x: Double, arrowMinX: Double) -> MenuBarItemGroup {
        x + 0.5 < arrowMinX ? .hidden : .visible
    }
}

/// Menu bar extras are mirrored onto every display, and AX reports each item in
/// the global coordinate space of whichever display it currently belongs to. A
/// bar that spans two displays therefore mixes x ranges (0…1920 and 1920…3390),
/// so raw comparison against the arrow's x is meaningless.
///
/// Normalizing to the item's own display makes mirrored bars comparable: an item
/// that sits 200 points left of the right edge is 200 points left of the right
/// edge on every display.
public enum MenuBarCoordinates {
    public static func relativeX(_ x: Double, screens: [Rect]) -> Double {
        guard !screens.isEmpty else { return x }
        let ordered = screens.sorted { $0.x < $1.x }
        if let host = ordered.first(where: { x >= $0.x && x <= $0.x + $0.width }) {
            return x - host.x
        }
        // Off-screen items are parked to the left of every display while the
        // separator is expanded; attribute them to the nearest edge.
        if let leftmost = ordered.first, x < leftmost.x {
            return x - leftmost.x
        }
        if let rightmost = ordered.last {
            return x - rightmost.x
        }
        return x
    }
}

/// The user's intended grouping and order.
///
/// Only managed (`.app`) items appear here. The bar itself always stays
/// authoritative: `adopt` mirrors observed order after the user drags an icon,
/// and `arrange` derives the desired order from what is stored.
public struct MenuBarLayout: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    /// Managed item ids, left to right.
    public var order: [String]
    public var groups: [String: MenuBarItemGroup]

    public init(
        version: Int = MenuBarLayout.currentVersion,
        order: [String] = [],
        groups: [String: MenuBarItemGroup] = [:]
    ) {
        self.version = version
        self.order = order
        self.groups = groups
    }

    /// A file written by a newer BarFold is read as an empty layout instead of
    /// being half-applied.
    public var isCompatible: Bool { version <= Self.currentVersion }

    public func group(for id: String) -> MenuBarItemGroup? {
        groups[id]
    }

    /// Mirrors the bar: order follows live geometry, membership drops stale ids.
    ///
    /// Observed groups are written through as well. Without them a layout store
    /// that never took a snapshot would believe every item is hidden, and undo
    /// would "restore" items to the side they were already on.
    public mutating func adopt(
        liveIDs: [String],
        observedGroups: [String: MenuBarItemGroup] = [:]
    ) {
        let live = Set(liveIDs)
        order = uniq(liveIDs)
        groups = groups.filter { live.contains($0.key) }
        for (id, group) in observedGroups where live.contains(id) {
            groups[id] = group
        }
    }

    public mutating func setGroup(_ group: MenuBarItemGroup, for id: String) {
        if !order.contains(id) { order.append(id) }
        groups[id] = group
    }

    public mutating func setGroup(_ group: MenuBarItemGroup, for id: String, at index: Int) {
        setGroup(group, for: id)
        move(id, to: index, in: group)
    }

    /// Moves `id` to `index` among the members of `group`. The index is clamped,
    /// so a caller that counted stale positions still lands somewhere sane.
    public mutating func move(_ id: String, to index: Int, in group: MenuBarItemGroup) {
        groups[id] = group
        var ids = order
        ids.removeAll { $0 == id }

        let members = ids.filter { groups[$0] == group }
        let clamped = max(0, min(index, members.count))
        let insertion: Int
        if clamped < members.count, let anchor = ids.firstIndex(of: members[clamped]) {
            insertion = anchor
        } else if let last = members.last, let anchor = ids.firstIndex(of: last) {
            insertion = anchor + 1
        } else {
            insertion = ids.count
        }
        ids.insert(id, at: insertion)
        order = uniq(ids)
    }

    /// Drops ids that no longer exist. Used by snapshots so the file cannot grow
    /// without bound as apps are installed and removed.
    public mutating func prune(keeping live: Set<String>) {
        order.removeAll { !live.contains($0) }
        groups = groups.filter { live.contains($0.key) }
    }

    public func members(of group: MenuBarItemGroup) -> [String] {
        order.filter { groups[$0] == group }
    }

    private func uniq(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// Desired left-to-right order per group with live items reconciled in.
    /// Unknown live items default to `hidden` and land at the left end, which is
    /// where macOS puts a freshly launched extra.
    public func arrange(live: [MenuBarItemSnapshot]) -> [MenuBarItemGroup: [String]] {
        let liveByID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var known = order.filter { liveByID[$0] != nil }
        let unknown = live.map(\.id)
            .filter { !known.contains($0) }
            .sorted { lhs, rhs in
                let lx = liveByID[lhs]?.x ?? 0
                let rx = liveByID[rhs]?.x ?? 0
                return lx == rx ? lhs < rhs : lx < rx
            }

        var visible = known.filter { groups[$0] == .visible }
        var hidden = known.filter { groups[$0] != .visible }
        hidden.insert(contentsOf: unknown, at: 0)
        known.removeAll()
        return [.visible: visible, .hidden: hidden]
    }
}

/// One step of a multi-item move. `before` is the item the selection should be
/// inserted in front of; `nil` means the group's edge (right of the arrow for
/// `visible`, left of the separator for `hidden`).
public struct MenuBarBatchStep: Sendable, Equatable {
    public var id: String
    public var group: MenuBarItemGroup
    public var before: String?
    /// Used only when `before` is nil; lets a caller append at the far end of the
    /// visible group instead of always landing at the arrow.
    public var index: Int?

    public init(id: String, group: MenuBarItemGroup, before: String?, index: Int? = nil) {
        self.id = id
        self.group = group
        self.before = before
        self.index = index
    }
}

/// Turns "move these items in front of that one" into an ordered list of single
/// insertions.
///
/// Insertion order is load-bearing. Prepending at the group's front edge has to
/// run in reverse, while a fixed anchor and the hidden group's back edge run
/// forward; anything else scrambles the selection's internal order.
public enum MenuBarBatchPlanner {
    public static func plan(
        ids: [String],
        group: MenuBarItemGroup,
        before anchor: String?,
        live: [MenuBarItemSnapshot]
    ) -> [MenuBarBatchStep] {
        let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let selected = ids
            .filter { byID[$0]?.isManaged == true }
            .sorted { lhs, rhs in
                let lx = byID[lhs]?.x ?? 0
                let rx = byID[rhs]?.x ?? 0
                return lx == rx ? lhs < rhs : lx < rx
            }
        guard !selected.isEmpty else { return [] }

        if let anchor {
            return selected.map { MenuBarBatchStep(id: $0, group: group, before: anchor) }
        }
        let ordered = group == .visible ? selected.reversed() : Array(selected)
        return ordered.map { MenuBarBatchStep(id: $0, group: group, before: nil) }
    }
}

/// Where a drag has to start and end so an item lands in a given slot.
///
/// All points are in global top-left (CGEvent) coordinates. The plan is pure and
/// testable; the mover posts the events and then verifies the outcome, because
/// the system decides the final insertion side.
public struct MenuBarDragPlan: Sendable, Equatable {
    public var source: Point
    public var destination: Point
    public var expectedGroup: MenuBarItemGroup
    public var expectedIndex: Int

    public init(source: Point, destination: Point, expectedGroup: MenuBarItemGroup, expectedIndex: Int) {
        self.source = source
        self.destination = destination
        self.expectedGroup = expectedGroup
        self.expectedIndex = expectedIndex
    }
}

public enum MenuBarDragGeometry {
    /// Gap between a drop point and the item it anchors to.
    public static let inset: Double = 6

    public static func plan(
        item: MenuBarItemSnapshot,
        to group: MenuBarItemGroup,
        index: Int,
        items: [MenuBarItemSnapshot],
        arrow: Rect,
        separator: Rect
    ) -> MenuBarDragPlan {
        let centerY = arrow.y + arrow.height / 2
        let source = Point(x: item.x + item.width / 2, y: centerY)

        // Raw snapshots carry a placeholder group for app items, so the live side
        // of the arrow has to be derived from geometry. Using the placeholder
        // silently turned every "insert at index N" into "insert at the edge".
        func side(_ candidate: MenuBarItemSnapshot) -> MenuBarItemGroup {
            candidate.observedGroup
                ?? MenuBarItemIdentity.classify(x: candidate.x, arrowMinX: arrow.x)
        }

        let targets = items
            .filter { $0.isManaged && $0.id != item.id && side($0) == group }
            .sorted { $0.x < $1.x }
        let slot = max(0, min(index, targets.count))
        let destinationX: Double

        switch group {
        case .visible:
            // The visible group lives right of the arrow, so its left edge is the
            // arrow's right edge and appending means passing the last item.
            if slot == 0 {
                destinationX = arrow.x + arrow.width + inset
            } else if slot >= targets.count {
                let last = targets[targets.count - 1]
                destinationX = last.x + last.width + inset
            } else {
                destinationX = targets[slot].x + 2
            }
        case .hidden:
            // The hidden group ends at the separator; the arrow itself is never a
            // drop target, or it would be dragged along with the item.
            if targets.isEmpty || slot >= targets.count {
                destinationX = separator.x - inset
            } else if slot == 0 {
                destinationX = targets[0].x - inset
            } else {
                destinationX = targets[slot].x + 2
            }
        }

        return MenuBarDragPlan(
            source: source,
            destination: Point(x: destinationX, y: centerY),
            expectedGroup: group,
            expectedIndex: slot
        )
    }
}

/// Everything the catalog knows how to report, with the layout applied.
public enum MenuBarItemReport {
    /// Applies stored groups to live items and assigns per-group indices.
    public static func apply(
        layout: MenuBarLayout,
        live: [MenuBarItemSnapshot]
    ) -> [MenuBarItemSnapshot] {
        let managed = live.filter(\.isManaged)
        let arrangement = layout.arrange(live: managed)
        var indexByID: [String: Int] = [:]
        for group in MenuBarItemGroup.allCases {
            for (offset, id) in (arrangement[group] ?? []).enumerated() {
                indexByID[id] = offset
            }
        }
        return live.map { item in
            var copy = item
            if item.isManaged {
                copy.group = layout.group(for: item.id) ?? item.observedGroup ?? .hidden
                copy.index = indexByID[item.id] ?? 0
            } else {
                copy.group = item.observedGroup ?? item.group
                copy.index = 0
            }
            return copy
        }
    }
}
