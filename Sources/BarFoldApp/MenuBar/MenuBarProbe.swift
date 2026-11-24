import AppKit
import BarFoldProtocol

struct StatusWindowRecord: Sendable {
    let ownerPID: Int32
    let ownerName: String
    let windowNumber: Int
    let layer: Int
    let frame: Rect
    let isOnscreen: Bool
}

enum MenuBarProbe {
    /// Every layer-25 window, including the wide menu-bar background window the
    /// system owns. `statusItemFrames()` narrows this to real icons for hover.
    static func statusWindows() -> [StatusWindowRecord] {
        guard let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var records: [StatusWindowRecord] = []
        for window in raw {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 25 else { continue }
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = ScreenMapping.appKitRect(fromCGWindowBounds: bounds) else { continue }
            records.append(StatusWindowRecord(
                ownerPID: Int32(window[kCGWindowOwnerPID as String] as? Int ?? 0),
                ownerName: window[kCGWindowOwnerName as String] as? String ?? "",
                windowNumber: window[kCGWindowNumber as String] as? Int ?? 0,
                layer: layer,
                frame: frame,
                isOnscreen: window[kCGWindowIsOnscreen as String] as? Bool ?? false
            ))
        }
        return records
    }

    /// Frames of visible menu bar icons. Excludes our own items and the
    /// full-width menu bar background so hovering the arrow still toggles.
    static func statusItemFrames(excludingPID pid: pid_t = getpid()) -> [Rect] {
        statusWindows()
            .filter { $0.ownerPID != Int32(pid) }
            .filter { $0.isOnscreen }
            .filter { $0.frame.width > 1 && $0.frame.width < 220 }
            .filter { $0.frame.height > 1 && $0.frame.height < 80 }
            .map(\.frame)
    }

    static func visibleStatusWindowCount(excludingPID pid: pid_t = getpid()) -> Int {
        statusWindows()
            .filter { $0.ownerPID != Int32(pid) }
            .filter { $0.isOnscreen }
            .filter { $0.frame.width > 1 && $0.frame.width < 220 }
            .count
    }

    /// A pop-up menu is at level 101; while one is open, auto-collapse must wait
    /// even if the pointer has already left the menu bar.
    static func hasOpenMenu() -> Bool {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return raw.contains { window in
            guard let layer = window[kCGWindowLayer as String] as? Int else { return false }
            return layer == 101
        }
    }

    static func otherManagerNames() -> [String] {
        let knownBundleIDs: Set<String> = [
            "cn.better365.ibar",
            "com.dwarvesv.minimalbar",
            "com.jordanbaird.ice",
            "com.surteesstudios.bartender",
        ]
        // Exact names only: a substring match would classify "Service" as "Ice".
        let knownNames: Set<String> = ["ibar", "hidden bar", "ice", "bartender", "thaw", "menutidy"]
        var names = Set<String>()
        for app in NSWorkspace.shared.runningApplications {
            let bundle = app.bundleIdentifier?.lowercased() ?? ""
            let name = app.localizedName ?? ""
            let lowerName = name.lowercased()
            if knownBundleIDs.contains(bundle) || knownNames.contains(lowerName) {
                names.insert(name.isEmpty ? bundle : name)
            }
        }
        return names.sorted()
    }

    static func runningManagerSummary() -> JSONValue {
        .array(otherManagerNames().map { .string($0) })
    }
}
