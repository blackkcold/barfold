import AppKit
import BarFoldProtocol

@MainActor
final class StatusItemController: NSObject {
    static let toggleAutosaveName = "barfold_toggle"
    static let separatorAutosaveName = "barfold_separator"
    static let canaryAutosaveName = "barfold_canary"

    private(set) var toggleItem: NSStatusItem!
    private(set) var separatorItem: NSStatusItem?
    private(set) var canaryItem: NSStatusItem?
    private(set) var engine: MenuBarEngine!

    let capability: CapabilityReport
    let testMode: Bool

    var onToggle: (() -> Void)?
    var onMenu: ((NSStatusItem) -> Void)?

    init(capability: CapabilityReport, testMode: Bool) {
        self.capability = capability
        self.testMode = testMode
        super.init()
        seedPreferredPositions()
        createItems()
    }

    var isCollapsed: Bool { engine?.isCollapsed ?? false }
    var separatorLength: Double { Double(separatorItem?.length ?? 0) }
    var separatorVisible: Bool { separatorItem?.isVisible ?? false }

    var toggleFrame: NSRect? { toggleItem.button?.window?.frame }
    /// Hidden status items keep a stale window parked off-layout, so visibility
    /// has to be part of the answer; otherwise callers compute drops against
    /// coordinates like (0, -15).
    var separatorFrame: NSRect? {
        guard separatorItem?.isVisible != false else { return nil }
        return separatorItem?.button?.window?.frame
    }
    var canaryFrame: NSRect? { canaryItem?.button?.window?.frame }
    var canaryOnScreen: Bool {
        guard let frame = canaryFrame else { return false }
        return MenuBarGeometry.isOnAnyScreen(
            Rect(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height),
            screens: ScreenMapping.descriptors
        )
    }

    // MARK: - Position pinning

    /// AppKit parks a newly created status item left of an already overflowing
    /// bar (measured x=-4188 while iBar was collapsed). Seeding the autosaved
    /// preferred position *before* creation lands the arrow in the visible
    /// region. Larger values are further left; 250 is just left of the system
    /// section and 265 keeps the separator immediately left of the arrow.
    private func seedPreferredPositions() {
        let defaults = UserDefaults.standard
        let toggleKey = "NSStatusItem Preferred Position \(Self.toggleAutosaveName)"
        let separatorKey = "NSStatusItem Preferred Position \(Self.separatorAutosaveName)"
        let canaryKey = "NSStatusItem Preferred Position \(Self.canaryAutosaveName)"

        let togglePosition: Double
        if let stored = defaults.object(forKey: toggleKey) as? Double,
           stored >= 0, stored <= 4000 {
            togglePosition = stored
        } else {
            togglePosition = 250
        }

        defaults.set(togglePosition, forKey: toggleKey)
        defaults.set(togglePosition + 15, forKey: separatorKey)
        defaults.set(togglePosition + 45, forKey: canaryKey)
        defaults.synchronize()
    }

    /// A 1 pt hairline that turns the separator's 17 pt window into a deliberate
    /// rule instead of an invisible hole.
    ///
    /// The image is exactly as wide as the item's content area (the separator's
    /// `length`), because AppKit clips anything wider: a 17 pt canvas rendered
    /// nothing at all, since only its transparent centre column survived. The
    /// 16 pt of window padding on either side is what gives the rule its air.
    static func separatorRuleImage() -> NSImage {
        let lineHeight: CGFloat = 12
        let imageHeight: CGFloat = 24
        let image = NSImage(size: NSSize(width: 1, height: imageHeight), flipped: false) { rect in
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSBezierPath(
                roundedRect: NSRect(
                    x: 0,
                    y: (rect.height - lineHeight) / 2,
                    width: 1,
                    height: lineHeight
                ),
                xRadius: 0.5,
                yRadius: 0.5
            ).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    private func createItems() {
        // Creation order is load-bearing: later items appear to the left. The
        // arrow must exist first so it ends up right of the separator.
        toggleItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        toggleItem.autosaveName = Self.toggleAutosaveName
        if let button = toggleItem.button {
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            button.toolTip = L10n.t("BarFold：收起或展开菜单栏图标", "BarFold: collapse or expand menu bar icons")
        }

        if capability.kind == .lengthSpacer {
            // AppKit persists NSStatusItem.isVisible per autosave name. A single
            // hidden state — ours or another tool's — would otherwise keep the
            // separator invisible forever, and the engine cannot collapse without
            // it. Clear the stale flag and force the item back on.
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: "NSStatusItem VisibleCC \(Self.separatorAutosaveName)")
            defaults.removeObject(forKey: "NSStatusItem Visible \(Self.separatorAutosaveName)")
            separatorItem = NSStatusBar.system.statusItem(withLength: CGFloat(MenuBarGeometry.expandedLength))
            separatorItem?.autosaveName = Self.separatorAutosaveName
            separatorItem?.isVisible = true
            if let separator = separatorItem {
                separator.button?.title = ""
                separator.button?.imagePosition = .imageOnly
                separator.button?.imageScaling = .scaleNone
                separator.button?.image = Self.separatorRuleImage()
                separator.button?.isEnabled = true
                separator.button?.setAccessibilityElement(false)
                // The 10,000pt window must never swallow clicks meant for the
                // desktop behind the hidden area.
                DispatchQueue.main.async { [weak separator] in
                    separator?.button?.window?.ignoresMouseEvents = true
                }
            }
            engine = LengthSpacerEngine(
                separator: separatorItem!,
                toggle: toggleItem,
                collapsedLength: CGFloat(MenuBarGeometry.collapsedLength(for: ScreenMapping.descriptors))
            )
        } else {
            engine = UnsupportedEngine(detail: capability.detail)
        }

        if testMode {
            canaryItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            canaryItem?.autosaveName = Self.canaryAutosaveName
            if let button = canaryItem?.button {
                button.title = "C"
                button.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Canary")
                button.image?.isTemplate = true
                button.toolTip = "BarFold test canary"
                button.setAccessibilityElement(false)
            }
        }

        refreshIcon()
    }

    @objc private func handleClick() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isRightClick {
            onMenu?(toggleItem)
        } else {
            onToggle?()
        }
    }

    func refreshIcon() {
        let collapsed = isCollapsed
        let symbol = collapsed ? "chevron.right" : "chevron.left"
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        toggleItem.button?.image = image
        toggleItem.button?.setAccessibilityLabel(collapsed ? L10n.expand : L10n.collapse)
        toggleItem.button?.toolTip = collapsed
            ? L10n.t("点击展开被收起的图标", "Click to expand hidden icons")
            : L10n.t("点击收起菜单栏图标", "Click to collapse menu bar icons")
    }

    func snapshotData() -> [String: JSONValue] {
        var data: [String: JSONValue] = [
            "collapsed": .bool(isCollapsed),
            "engine": .string(engine.kind.rawValue),
            "engineAvailable": .bool(engine.isAvailable),
            "separatorLength": .number(separatorLength),
            "separatorVisible": .bool(separatorVisible),
            "capability": .string(capability.detail),
            "osVersion": .string(capability.osVersion),
            "testMode": .bool(testMode),
        ]
        if let frame = toggleFrame {
            data["toggleFrame"] = .object([
                "x": .number(Double(frame.origin.x)),
                "y": .number(Double(frame.origin.y)),
                "width": .number(Double(frame.width)),
                "height": .number(Double(frame.height)),
            ])
        }
        if let frame = separatorFrame {
            data["separatorFrame"] = .object([
                "x": .number(Double(frame.origin.x)),
                "y": .number(Double(frame.origin.y)),
                "width": .number(Double(frame.width)),
                "height": .number(Double(frame.height)),
            ])
        }
        if let frame = canaryFrame {
            data["canaryFrame"] = .object([
                "x": .number(Double(frame.origin.x)),
                "y": .number(Double(frame.origin.y)),
                "width": .number(Double(frame.width)),
                "height": .number(Double(frame.height)),
            ])
            data["canaryOnScreen"] = .bool(canaryOnScreen)
        }
        return data
    }
}
