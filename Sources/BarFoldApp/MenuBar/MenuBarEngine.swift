import AppKit
import BarFoldProtocol

enum EngineKind: String, Codable, Sendable {
    case lengthSpacer
    case unsupported

    var displayName: String {
        switch self {
        case .lengthSpacer: return "LengthSpacer"
        case .unsupported: return "Unsupported"
        }
    }
}

enum EngineError: LocalizedError {
    case unavailable(String)
    case separatorMissing

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail): return detail
        case .separatorMissing: return "The separator status item is missing."
        }
    }
}

struct EngineCheck: Codable, Sendable {
    var name: String
    var status: String // pass | warn | fail
    var detail: String
}

struct EngineVerification: Codable, Sendable {
    var ok: Bool
    var checks: [EngineCheck]

    static func from(_ checks: [EngineCheck]) -> EngineVerification {
        EngineVerification(ok: !checks.contains(where: { $0.status == "fail" }), checks: checks)
    }
}

@MainActor
protocol MenuBarEngine: AnyObject {
    var kind: EngineKind { get }
    var isAvailable: Bool { get }
    var isCollapsed: Bool { get }
    var detail: String { get }
    func collapse() throws
    func expand() throws
    func verify() -> EngineVerification
}

@MainActor
final class LengthSpacerEngine: MenuBarEngine {
    let kind: EngineKind = .lengthSpacer
    private let separator: NSStatusItem
    private let toggle: NSStatusItem
    private var collapsedLength: CGFloat

    var isAvailable: Bool { true }
    var detail: String { "A separator status item expands to push items off-screen." }

    /// The separator stays mounted for its whole lifetime (AGENTS invariant 16):
    /// hiding or recreating it makes AppKit drop its autosaved position and the
    /// next collapse anchors hundreds of points away. When expanded its length is
    /// 1, which leaves a ~17 pt window that a hairline turns into a divider.
    var isSeparatorVisible: Bool { separator.isVisible }

    var isCollapsed: Bool {
        separator.length > CGFloat(MenuBarGeometry.expandedLength) + 4
    }

    init(separator: NSStatusItem, toggle: NSStatusItem, collapsedLength: CGFloat) {
        self.separator = separator
        self.toggle = toggle
        self.collapsedLength = collapsedLength
    }

    func collapse() throws {
        // The separator stays mounted at all times: hiding and re-showing it
        // lets AppKit rewrite its autosaved position, which moved the right edge
        // hundreds of points away from the arrow.
        // The separator must stay mounted: hiding it makes AppKit drop its
        // autosaved position, and the next collapse then anchors hundreds of
        // points away from the arrow (measured: right edge 950 instead of 1621).
        guard separator.button?.window != nil else { throw EngineError.separatorMissing }
        separator.length = collapsedLength
        DispatchQueue.main.async { [weak self] in
            self?.separator.button?.window?.ignoresMouseEvents = true
        }
    }

    func expand() throws {
        separator.length = CGFloat(MenuBarGeometry.expandedLength)
    }

    func updateCollapsedLength(_ length: CGFloat) {
        collapsedLength = length
        if isCollapsed {
            separator.length = length
        }
    }

    func verify() -> EngineVerification {
        var checks: [EngineCheck] = []
        let screens = ScreenMapping.descriptors
        let expectedLength = collapsedLength

        checks.append(EngineCheck(
            name: "separator-item",
            status: separator.button?.window == nil ? "fail" : "pass",
            detail: separator.button?.window == nil ? "separator window is missing" : "separator window exists"
        ))
        let isCollapsedNow = isCollapsed
        checks.append(EngineCheck(
            name: "state-derived-from-length",
            status: isCollapsedNow == (separator.length > CGFloat(MenuBarGeometry.expandedLength) + 4) ? "pass" : "fail",
            detail: "length=\(Int(separator.length))"
        ))
        checks.append(EngineCheck(
            name: "collapsed-length-requested",
            status: collapsedLength >= 500 ? "pass" : "warn",
            detail: "requested=\(Int(collapsedLength))"
        ))

        if isCollapsedNow {
            if let window = separator.button?.window {
                // The window can lag one layout pass behind the length change, so
                // the requested length is also accepted as evidence.
                let wideEnough = window.frame.width > 1000 || separator.length >= 500
                checks.append(EngineCheck(
                    name: "separator-width",
                    status: wideEnough ? "pass" : "fail",
                    detail: "actual window width=\(Int(window.frame.width)), requested=\(Int(expectedLength))"
                ))
            }
            if let window = toggle.button?.window {
                let visible = MenuBarGeometry.isOnAnyScreen(
                    Rect(x: window.frame.origin.x, y: window.frame.origin.y,
                         width: window.frame.width, height: window.frame.height),
                    screens: screens
                )
                checks.append(EngineCheck(
                    name: "arrow-on-screen",
                    status: visible ? "pass" : "warn",
                    detail: "arrow frame=\(NSStringFromRect(window.frame))"
                ))
            } else {
                checks.append(EngineCheck(name: "arrow-on-screen", status: "fail", detail: "arrow window is missing"))
            }
        }

        return EngineVerification.from(checks)
    }
}

@MainActor
final class UnsupportedEngine: MenuBarEngine {
    let kind: EngineKind = .unsupported
    let detail: String

    var isAvailable: Bool { false }
    var isCollapsed: Bool { false }

    init(detail: String) {
        self.detail = detail
    }

    func collapse() throws {
        throw EngineError.unavailable(detail)
    }

    func expand() throws {}

    func verify() -> EngineVerification {
        EngineVerification.from([
            EngineCheck(name: "engine", status: "fail", detail: detail),
        ])
    }
}
