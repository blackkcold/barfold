import BarFoldProtocol
import Combine
import Foundation

enum SettingsError: LocalizedError, Equatable {
    case invalidPatch
    case unknownKey(String)
    case invalidValue(String, String)
    case invalidHotkey(String)

    var errorDescription: String? {
        switch self {
        case .invalidPatch:
            return "settings patch must be a JSON object"
        case .unknownKey(let key):
            return "unknown setting: \(key)"
        case .invalidValue(let key, let reason):
            return "invalid value for \(key): \(reason)"
        case .invalidHotkey(let reason):
            return "invalid hotkey: \(reason)"
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    private enum Keys {
        static let hoverEnabled = "barfold.hoverEnabled"
        static let hoverDelay = "barfold.hoverDelay"
        static let autoCollapseEnabled = "barfold.autoCollapseEnabled"
        static let collapseDelay = "barfold.collapseDelay"
        static let hotkey = "barfold.hotkey"
        static let showNewIconHint = "barfold.showNewIconHint"
        static let hasCompletedOnboarding = "barfold.hasCompletedOnboarding"
        static let updateAutomatically = "barfold.updateAutomatically"
        static let engineOverride = "barfold.engineOverride"
        static let lastCollapsed = "barfold.lastCollapsed"
    }

    @Published var hoverEnabled: Bool {
        didSet { defaults.set(hoverEnabled, forKey: Keys.hoverEnabled) }
    }

    @Published var hoverDelay: Double {
        didSet { defaults.set(hoverDelay, forKey: Keys.hoverDelay) }
    }

    @Published var autoCollapseEnabled: Bool {
        didSet { defaults.set(autoCollapseEnabled, forKey: Keys.autoCollapseEnabled) }
    }

    @Published var collapseDelay: Double {
        didSet { defaults.set(collapseDelay, forKey: Keys.collapseDelay) }
    }

    @Published var hotkey: KeyCombo? {
        didSet { persistHotkey() }
    }

    @Published var showNewIconHint: Bool {
        didSet { defaults.set(showNewIconHint, forKey: Keys.showNewIconHint) }
    }

    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    @Published var updateAutomatically: Bool {
        didSet { defaults.set(updateAutomatically, forKey: Keys.updateAutomatically) }
    }

    @Published var engineOverride: String {
        didSet { defaults.set(engineOverride, forKey: Keys.engineOverride) }
    }

    /// Last observed state, used only to restore the user's intent after launch.
    @Published var lastCollapsed: Bool {
        didSet { defaults.set(lastCollapsed, forKey: Keys.lastCollapsed) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        self.hoverEnabled = defaults.object(forKey: Keys.hoverEnabled) as? Bool ?? true
        self.hoverDelay = defaults.object(forKey: Keys.hoverDelay) as? Double ?? 0.25
        self.autoCollapseEnabled = defaults.object(forKey: Keys.autoCollapseEnabled) as? Bool ?? true
        self.collapseDelay = defaults.object(forKey: Keys.collapseDelay) as? Double ?? 0.6
        self.showNewIconHint = defaults.object(forKey: Keys.showNewIconHint) as? Bool ?? true
        self.hasCompletedOnboarding = defaults.object(forKey: Keys.hasCompletedOnboarding) as? Bool ?? false
        self.updateAutomatically = defaults.object(forKey: Keys.updateAutomatically) as? Bool ?? true
        self.engineOverride = defaults.string(forKey: Keys.engineOverride) ?? "auto"
        self.lastCollapsed = defaults.object(forKey: Keys.lastCollapsed) as? Bool ?? false

        if let data = defaults.data(forKey: Keys.hotkey),
           let combo = try? JSONDecoder().decode(KeyCombo.self, from: data) {
            self.hotkey = combo
        } else if defaults.object(forKey: Keys.hotkey) == nil {
            self.hotkey = .defaultCombo
        } else {
            self.hotkey = nil
        }
    }

    private func persistHotkey() {
        if let hotkey, let data = try? JSONEncoder().encode(hotkey) {
            defaults.set(data, forKey: Keys.hotkey)
        } else {
            defaults.set(Data(), forKey: Keys.hotkey)
        }
    }

    var snapshot: JSONValue {
        .object([
            "hoverEnabled": .bool(hoverEnabled),
            "hoverDelay": .number(hoverDelay),
            "autoCollapseEnabled": .bool(autoCollapseEnabled),
            "collapseDelay": .number(collapseDelay),
            "hotkey": hotkey.map { .string($0.displayString) } ?? .null,
            "hotkeyKeyCode": hotkey.map { .number(Double($0.keyCode)) } ?? .null,
            "hotkeyModifiers": hotkey.map { .number(Double($0.modifiers)) } ?? .null,
            "showNewIconHint": .bool(showNewIconHint),
            "hasCompletedOnboarding": .bool(hasCompletedOnboarding),
            "updateAutomatically": .bool(updateAutomatically),
            "engineOverride": .string(engineOverride),
            "lastCollapsed": .bool(lastCollapsed),
        ])
    }

    /// Applies a JSON object. Unknown keys are rejected so a typo in a script
    /// fails loudly instead of silently doing nothing.
    @discardableResult
    func apply(patch: JSONValue) throws -> [String] {
        guard let object = patch.objectValue else { throw SettingsError.invalidPatch }
        var changed: [String] = []

        for (key, value) in object {
            switch key {
            case "hoverEnabled":
                guard let newValue = value.boolValue else { throw SettingsError.invalidValue(key, "expected a boolean") }
                if hoverEnabled != newValue { hoverEnabled = newValue; changed.append(key) }

            case "hoverDelay":
                guard let newValue = value.doubleValue else { throw SettingsError.invalidValue(key, "expected a number") }
                guard newValue >= 0, newValue <= 2 else { throw SettingsError.invalidValue(key, "must be between 0 and 2 seconds") }
                if hoverDelay != newValue { hoverDelay = newValue; changed.append(key) }

            case "autoCollapseEnabled":
                guard let newValue = value.boolValue else { throw SettingsError.invalidValue(key, "expected a boolean") }
                if autoCollapseEnabled != newValue { autoCollapseEnabled = newValue; changed.append(key) }

            case "collapseDelay":
                guard let newValue = value.doubleValue else { throw SettingsError.invalidValue(key, "expected a number") }
                guard newValue >= 0, newValue <= 5 else { throw SettingsError.invalidValue(key, "must be between 0 and 5 seconds") }
                if collapseDelay != newValue { collapseDelay = newValue; changed.append(key) }

            case "hotkey":
                let newValue: KeyCombo?
                if value.isNull {
                    newValue = nil
                } else if let text = value.stringValue {
                    guard let parsed = KeyCombo.parse(text) else {
                        throw SettingsError.invalidHotkey("could not parse '\(text)'")
                    }
                    newValue = parsed
                } else if let object = value.objectValue,
                          let keyCode = object["keyCode"]?.doubleValue,
                          let modifiers = object["modifiers"]?.doubleValue {
                    let combo = KeyCombo(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
                    guard combo.isValid else { throw SettingsError.invalidHotkey("combination needs a modifier and a known key") }
                    newValue = combo
                } else {
                    throw SettingsError.invalidValue(key, "expected a string, an object, or null")
                }
                if hotkey != newValue { hotkey = newValue; changed.append(key) }

            case "showNewIconHint":
                guard let newValue = value.boolValue else { throw SettingsError.invalidValue(key, "expected a boolean") }
                if showNewIconHint != newValue { showNewIconHint = newValue; changed.append(key) }

            case "hasCompletedOnboarding":
                guard let newValue = value.boolValue else { throw SettingsError.invalidValue(key, "expected a boolean") }
                if hasCompletedOnboarding != newValue { hasCompletedOnboarding = newValue; changed.append(key) }

            case "updateAutomatically":
                guard let newValue = value.boolValue else { throw SettingsError.invalidValue(key, "expected a boolean") }
                if updateAutomatically != newValue { updateAutomatically = newValue; changed.append(key) }

            case "engineOverride":
                guard let newValue = value.stringValue,
                      ["auto", "lengthSpacer", "unsupported"].contains(newValue) else {
                    throw SettingsError.invalidValue(key, "expected auto, lengthSpacer, or unsupported")
                }
                if engineOverride != newValue { engineOverride = newValue; changed.append(key) }

            default:
                throw SettingsError.unknownKey(key)
            }
        }

        return changed
    }
}
