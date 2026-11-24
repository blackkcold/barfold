import AppKit
import ApplicationServices
import BarFoldProtocol

/// Result of one read-only scan of the menu bar extras.
struct MenuBarCatalogScan: Sendable {
    var axTrusted: Bool
    var items: [MenuBarItemSnapshot]
    var arrowMinX: Double?
    var collapsed: Bool
    var scannedApps: Int
    var durationMs: Double
}

/// Enumerates menu bar extras through the Accessibility API.
///
/// Why AX and not `CGWindowList`: on macOS 26 every third-party extra is hosted
/// by Control Center, so window ownership only tells us "Control Center". The
/// accessibility tree still exposes each extra's owning process, which is the
/// only reliable way to name an item. Reading requires the Accessibility
/// permission; the folding engine itself stays permission-free.
///
/// The scan is read-only. It never writes AX positions (macOS marks them
/// `settable = false` for menu bar extras) and never posts events.
///
/// Deliberately not main-actor isolated: a cold scan costs seconds, so it must be
/// callable from a background queue. All state is per-call, and the AX API is
/// thread-safe, which makes the type safe to share.
final class MenuBarItemCatalog: @unchecked Sendable {
    static let systemBundleID = "com.apple.controlcenter"

    /// Extras hosted by other processes time out instead of blocking the scan.
    private let messagingTimeout: Float = 0.1

    func permissionStatus() -> [String: JSONValue] {
        let trusted = AXIsProcessTrusted()
        return [
            "axTrusted": .bool(trusted),
            "coreRequiresAccessibility": .bool(false),
            "itemManagementRequiresAccessibility": .bool(true),
            "detail": .string(trusted
                ? "图标管理可用；折叠、悬停、热键仍然零权限。"
                : "图标管理需要辅助功能权限；未授权时核心折叠功能不受影响。"),
        ]
    }

    func scan(
        arrowMinX: Double?,
        collapsed: Bool,
        screens: [Rect] = []
    ) -> MenuBarCatalogScan {
        let started = Date()
        let trusted = AXIsProcessTrusted()
        let arrowRelativeX = arrowMinX.map { MenuBarCoordinates.relativeX($0, screens: screens) }
        guard trusted else {
            return MenuBarCatalogScan(
                axTrusted: false,
                items: [],
                arrowMinX: arrowRelativeX,
                collapsed: collapsed,
                scannedApps: 0,
                durationMs: Date().timeIntervalSince(started) * 1000
            )
        }

        let ownPID = getpid()
        var raw: [RawItem] = []

        // Background-only processes and nested XPC helpers cannot own a status
        // item; probing every one of them cost ~6 s per scan on this machine.
        let apps = NSWorkspace.shared.runningApplications.filter {
            guard $0.processIdentifier != ownPID,
                  $0.activationPolicy != .prohibited,
                  let url = $0.bundleURL else { return false }
            let path = url.path
            if path.hasSuffix(".xpc") { return false }
            if path.contains(".app/Contents/") { return false }
            return true
        }
        for app in apps {
            let pid = app.processIdentifier
            // Control Center hosts every system extra and answers slower than a
            // normal app, so it gets a wider budget than the generic probe.
            let isSystemHost = app.bundleIdentifier == Self.systemBundleID
            let (extras, _) = extrasMenuBar(for: pid, timeout: isSystemHost ? 0.5 : nil)
            guard let extras else { continue }
            let bundleID = app.bundleIdentifier ?? "pid:\(pid)"
            let isSystem = bundleID == Self.systemBundleID
            for element in children(of: extras) {
                guard Self.string(element, kAXRoleAttribute) == (kAXMenuBarItemRole as String),
                      let frame = Self.frame(of: element),
                      frame.width > 2, frame.height > 2 else { continue }
                raw.append(RawItem(
                    pid: pid,
                    bundleID: bundleID,
                    kind: isSystem ? .system : .app,
                    identifier: Self.string(element, kAXIdentifierAttribute),
                    title: Self.string(element, kAXTitleAttribute).trimmingCharacters(in: .whitespacesAndNewlines),
                    detail: Self.string(element, kAXDescriptionAttribute).trimmingCharacters(in: .whitespacesAndNewlines),
                    appName: app.localizedName ?? bundleID,
                    frame: frame,
                    relativeX: MenuBarCoordinates.relativeX(frame.minX, screens: screens)
                ))
            }
        }

        raw.sort { lhs, rhs in
            if lhs.relativeX == rhs.relativeX { return lhs.bundleID < rhs.bundleID }
            return lhs.relativeX < rhs.relativeX
        }

        // Ordinals must count every item of a bundle in bar order, including the
        // ones that carry an accessibility identifier, or `n:` ids would shift
        // whenever a system extra appears or disappears.
        var counters: [String: Int] = [:]
        var items: [MenuBarItemSnapshot] = []
        items.reserveCapacity(raw.count)
        for entry in raw {
            let ordinal = counters[entry.bundleID, default: 0]
            counters[entry.bundleID] = ordinal + 1
            let id = MenuBarItemIdentity.make(
                bundleID: entry.bundleID,
                identifier: entry.identifier,
                ordinal: ordinal
            )
            let observed: MenuBarItemGroup? = {
                guard let arrowRelativeX else { return nil }
                return MenuBarItemIdentity.classify(x: entry.relativeX, arrowMinX: arrowRelativeX)
            }()
            items.append(MenuBarItemSnapshot(
                id: id,
                bundleID: entry.bundleID,
                appName: entry.kind == .system
                    ? (entry.detail.isEmpty ? "控制中心" : entry.detail)
                    : entry.appName,
                title: entry.kind == .system ? "" : entry.title,
                detail: entry.kind == .system ? entry.identifier : entry.detail,
                kind: entry.kind,
                x: entry.relativeX,
                y: entry.frame.minY,
                width: entry.frame.width,
                observedGroup: observed,
                group: entry.kind == .system ? .visible : .hidden
            ))
        }

        return MenuBarCatalogScan(
            axTrusted: true,
            items: items,
            arrowMinX: arrowRelativeX,
            collapsed: collapsed,
            scannedApps: apps.count,
            durationMs: Date().timeIntervalSince(started) * 1000
        )
    }

    // MARK: - Accessibility plumbing

    private struct RawItem {
        var pid: pid_t
        var bundleID: String
        var kind: MenuBarItemKind
        var identifier: String
        var title: String
        var detail: String
        var appName: String
        var frame: CGRect
        var relativeX: Double
    }

    private func extrasMenuBar(for pid: pid_t, timeout: Float? = nil) -> (AXUIElement?, AXError) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout ?? messagingTimeout)
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &raw)
        guard error == .success, let raw else { return (nil, error) }
        return ((raw as! AXUIElement), error)
    }

    /// Probes every candidate app once, off the main thread, right after launch.
    ///
    /// The first accessibility call to a process costs 40–200 ms while the system
    /// establishes the connection; repeat calls cost ~0.3 ms. Warming here keeps
    /// the settings page and `barfold items list` from freezing on their first use.
    nonisolated static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            guard AXIsProcessTrusted() else { return }
            let ownPID = getpid()
            for app in NSWorkspace.shared.runningApplications {
                let pid = app.processIdentifier
                guard pid != ownPID,
                      app.activationPolicy != .prohibited,
                      let url = app.bundleURL else { continue }
                let path = url.path
                if path.hasSuffix(".xpc") || path.contains(".app/Contents/") { continue }
                let element = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(element, 0.1)
                var raw: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(element, "AXExtrasMenuBar" as CFString, &raw)
            }
        }
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        guard let raw = Self.attribute(element, kAXChildrenAttribute) else { return [] }
        return (raw as? [AXUIElement]) ?? []
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(_ element: AXUIElement, _ key: String) -> String {
        guard let raw = attribute(element, key), CFGetTypeID(raw) == CFStringGetTypeID() else { return "" }
        return (raw as! CFString) as String
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = point(element, kAXPositionAttribute),
              let size = size(element, kAXSizeAttribute) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func point(_ element: AXUIElement, _ key: String) -> CGPoint? {
        guard let raw = attribute(element, key), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var value = CGPoint.zero
        guard AXValueGetValue(raw as! AXValue, .cgPoint, &value) else { return nil }
        return value
    }

    private static func size(_ element: AXUIElement, _ key: String) -> CGSize? {
        guard let raw = attribute(element, key), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var value = CGSize.zero
        guard AXValueGetValue(raw as! AXValue, .cgSize, &value) else { return nil }
        return value
    }
}
