import AppKit
import ApplicationServices
import BarFoldProtocol

enum MenuBarMoveError: LocalizedError, Equatable {
    case permissionDenied
    case itemMissing(String)
    case itemNotMovable(String)
    case itemOffScreen(String)
    case verificationFailed(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "菜单栏图标管理需要辅助功能权限。"
        case .itemMissing(let id):
            return "找不到菜单栏项：\(id)"
        case .itemNotMovable(let id):
            return "系统菜单栏项和 BarFold 自身项不能移动：\(id)"
        case .itemOffScreen(let id):
            return "菜单栏项不在屏幕内，无法拖动：\(id)"
        case .verificationFailed(let expected, let actual):
            return "移动后校验失败：期望 \(expected)，实际 \(actual)"
        }
    }
}

struct MenuBarMoveResult: Sendable, Equatable {
    var id: String
    var group: MenuBarItemGroup
    var index: Int
    var requestedIndex: Int
    var attempts: Int
    var durationMs: Double
}

/// Moves another app's menu bar extra with a synthesised `⌘`-drag.
///
/// There is no semantic alternative: on macOS 26 every extra reports
/// `AXPosition` as not settable, so AX cannot move them. The drag is the same
/// gesture a user makes while holding Command, and it is only ever posted for an
/// explicit request — never at launch, never in the background.
///
/// The mover is stateless and thread-safe so a long move can run off the main
/// thread while the menu bar stays responsive.
final class MenuBarItemMover: @unchecked Sendable {
    private let catalog: MenuBarItemCatalog
    private let eventSource = CGEventSource(stateID: .hidSystemState)
    /// Long enough for the window server to treat the sequence as a drag rather
    /// than a click; shorter delays make the insertion side unpredictable.
    private let stepDelay: useconds_t = 40_000

    init(catalog: MenuBarItemCatalog) {
        self.catalog = catalog
    }

    func move(
        id: String,
        to group: MenuBarItemGroup,
        before anchor: String? = nil,
        index: Int,
        arrow: Rect,
        separator: Rect,
        screens: [Rect],
        isCancelled: @escaping () -> Bool = { false }
    ) throws -> MenuBarMoveResult {
        guard AXIsProcessTrusted() else { throw MenuBarMoveError.permissionDenied }
        let started = Date()
        var attempts = 0

        for attempt in 1...2 {
            attempts = attempt
            if isCancelled() { throw MenuBarMoveError.verificationFailed(expected: "cancelled", actual: "cancelled") }
            let scan = catalog.scan(arrowMinX: arrow.x, collapsed: false, screens: screens)
            guard let item = scan.items.first(where: { $0.id == id }) else {
                throw MenuBarMoveError.itemMissing(id)
            }
            guard item.isManaged else { throw MenuBarMoveError.itemNotMovable(id) }
            guard item.x >= 0 else { throw MenuBarMoveError.itemOffScreen(id) }

            // A batch step names its anchor instead of a numeric index, because
            // indexes shift after every insertion.
            let resolvedIndex: Int
            if let anchor {
                let peers = scan.items
                    .filter { $0.isManaged && $0.id != id && observedGroup(of: $0, arrowMinX: arrow.x) == group }
                    .sorted { $0.x < $1.x }
                resolvedIndex = peers.firstIndex(where: { $0.id == anchor }) ?? peers.count
            } else {
                resolvedIndex = index
            }

            let plan = MenuBarDragGeometry.plan(
                item: item,
                to: group,
                index: resolvedIndex,
                items: scan.items,
                arrow: arrow,
                separator: separator
            )
            var destination = plan.destination
            if attempt > 1 {
                // The first drop did not cross the divider. Push the point one
                // item width further into the target side and try once more.
                let nudge = item.width + 12
                destination.x += group == .visible ? nudge : -nudge
            }

            postDrag(
                from: CGPoint(x: plan.source.x, y: plan.source.y),
                to: CGPoint(x: destination.x, y: destination.y)
            )
            usleep(320_000)

            let after = catalog.scan(arrowMinX: arrow.x, collapsed: false, screens: screens)
            guard let moved = after.items.first(where: { $0.id == id }) else {
                throw MenuBarMoveError.itemMissing(id)
            }
            // The raw scan carries a placeholder group for app items; only the
            // geometry says which side of the arrow the item actually landed on.
            let actual = observedGroup(of: moved, arrowMinX: arrow.x)
            if actual == group {
                let peers = after.items
                    .filter { $0.isManaged && $0.id != id }
                    .filter { observedGroup(of: $0, arrowMinX: arrow.x) == group }
                    .sorted { $0.x < $1.x }
                let landedIndex = peers.filter { $0.x < moved.x }.count
                return MenuBarMoveResult(
                    id: id,
                    group: actual,
                    index: landedIndex,
                    requestedIndex: resolvedIndex,
                    attempts: attempts,
                    durationMs: Date().timeIntervalSince(started) * 1000
                )
            }
            // Leave the run loop a beat before the retry so the bar can settle.
            usleep(120_000)
        }

        let final = catalog.scan(arrowMinX: arrow.x, collapsed: false, screens: screens)
        let actual = final.items.first(where: { $0.id == id })
        throw MenuBarMoveError.verificationFailed(
            expected: group.rawValue,
            actual: actual.map { "\(observedGroup(of: $0, arrowMinX: arrow.x).rawValue) x=\(Int($0.x))" } ?? "missing"
        )
    }

    private func observedGroup(of item: MenuBarItemSnapshot, arrowMinX: Double) -> MenuBarItemGroup {
        item.observedGroup ?? MenuBarItemIdentity.classify(x: item.x, arrowMinX: arrowMinX)
    }

    private func postDrag(from: CGPoint, to: CGPoint) {
        func post(_ type: CGEventType, _ point: CGPoint, command: Bool) {
            guard let event = CGEvent(
                mouseEventSource: eventSource,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: .left
            ) else { return }
            if command { event.flags = .maskCommand }
            event.post(tap: .cgSessionEventTap)
            usleep(stepDelay)
        }

        post(.mouseMoved, from, command: false)
        post(.leftMouseDown, from, command: true)
        let steps = 14
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let point = CGPoint(
                x: from.x + (to.x - from.x) * t,
                y: from.y + (to.y - from.y) * t
            )
            post(.leftMouseDragged, point, command: true)
        }
        post(.leftMouseUp, to, command: true)
    }
}
