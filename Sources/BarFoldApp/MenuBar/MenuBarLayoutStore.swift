import Foundation
import BarFoldProtocol

/// Persists the user's grouping and ordering for menu bar extras.
///
/// The file is a plain JSON document next to the control socket. It is a
/// preference, never a source of truth: every read is reconciled against a live
/// scan, and `adopt` mirrors whatever the bar currently shows. A corrupt or
/// future-version file is moved aside instead of being half-applied, so a bad
/// write can never fight the user's real layout.
@MainActor
final class MenuBarLayoutStore {
    private(set) var layout: MenuBarLayout
    private(set) var lastError: String?

    private let url: URL
    private let fileManager: FileManager

    init(
        url: URL = BarFoldPaths.supportDirectory.appendingPathComponent("layout.json", isDirectory: false),
        fileManager: FileManager = .default
    ) {
        self.url = url
        self.fileManager = fileManager
        self.layout = MenuBarLayout()
        reload()
    }

    var path: String { url.path }

    func reload() {
        lastError = nil
        guard fileManager.fileExists(atPath: url.path) else {
            layout = MenuBarLayout()
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(MenuBarLayout.self, from: data)
            guard decoded.isCompatible else {
                quarantine(reason: "layout.json was written by a newer BarFold (version \(decoded.version))")
                layout = MenuBarLayout()
                return
            }
            layout = decoded
        } catch {
            quarantine(reason: "layout.json could not be read: \(error.localizedDescription)")
            layout = MenuBarLayout()
        }
    }

    @discardableResult
    func save() -> Bool {
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var document = layout
            document.version = MenuBarLayout.currentVersion
            let data = try encoder.encode(document)
            try data.write(to: url, options: .atomic)
            layout = document
            lastError = nil
            return true
        } catch {
            lastError = "layout.json could not be written: \(error.localizedDescription)"
            return false
        }
    }

    /// Mirrors observed order. Returns true when the stored layout changed.
    @discardableResult
    func adopt(liveIDs: [String], observedGroups: [String: MenuBarItemGroup] = [:]) -> Bool {
        var next = layout
        next.adopt(liveIDs: liveIDs, observedGroups: observedGroups)
        guard next != layout else { return false }
        layout = next
        save()
        return true
    }

    /// Records the live bar as the desired layout: order from geometry, groups
    /// from the arrow boundary, unknown items defaulting to hidden.
    @discardableResult
    func snapshot(from items: [MenuBarItemSnapshot]) -> Bool {
        let managed = items.filter(\.isManaged).sorted { $0.x < $1.x }
        var next = MenuBarLayout()
        next.adopt(liveIDs: managed.map(\.id))
        for item in managed {
            let group = layout.group(for: item.id) ?? item.observedGroup ?? .hidden
            next.setGroup(group, for: item.id)
        }
        guard next != layout else { return false }
        layout = next
        save()
        return true
    }

    /// Records the outcome of a successful move so a later snapshot cannot undo
    /// it if the bar is reshuffled before the next scan.
    @discardableResult
    func apply(result: MenuBarMoveResult) -> Bool {
        var next = layout
        next.setGroup(result.group, for: result.id, at: result.index)
        guard next != layout else { return false }
        layout = next
        save()
        return true
    }

    func json() -> JSONValue {
        var object: [String: JSONValue] = [
            "path": .string(path),
            "version": .number(Double(layout.version)),
            "compatible": .bool(layout.isCompatible),
            "order": .array(layout.order.map { .string($0) }),
            "visible": .array(layout.members(of: .visible).map { .string($0) }),
            "hidden": .array(layout.members(of: .hidden).map { .string($0) }),
            "groups": .object(layout.groups.mapValues { .string($0.rawValue) }),
        ]
        object["error"] = .string(lastError ?? "")
        return .object(object)
    }

    /// Moves an unreadable file aside so the next launch starts clean and the
    /// user's old data is still on disk for support.
    private func quarantine(reason: String) {
        lastError = reason
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("layout.corrupt-\(stamp).json")
        try? fileManager.moveItem(at: url, to: backup)
    }
}
