import Foundation

/// A global hotkey in Carbon's terms. Stored as virtual key code plus Carbon
/// modifier flags so the app can register it without translating twice.
public struct KeyCombo: Codable, Sendable, Equatable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let controlModifier: UInt32 = 4096
    public static let optionModifier: UInt32 = 2048
    public static let shiftModifier: UInt32 = 512
    public static let commandModifier: UInt32 = 256

    public var hasControl: Bool { modifiers & Self.controlModifier != 0 }
    public var hasOption: Bool { modifiers & Self.optionModifier != 0 }
    public var hasShift: Bool { modifiers & Self.shiftModifier != 0 }
    public var hasCommand: Bool { modifiers & Self.commandModifier != 0 }

    /// A hotkey with no modifier would steal ordinary typing; require at least
    /// one of Control, Option, or Command. Shift alone is not enough.
    public var isValid: Bool {
        guard keyCode != 0 else { return false }
        guard modifiers & (Self.controlModifier | Self.optionModifier | Self.commandModifier) != 0 else {
            return false
        }
        return KeyCodeMap.name(for: keyCode) != nil
    }

    public var displayString: String {
        var result = ""
        if hasControl { result += "⌃" }
        if hasOption { result += "⌥" }
        if hasShift { result += "⇧" }
        if hasCommand { result += "⌘" }
        result += KeyCodeMap.displayName(for: keyCode)
        return result
    }

    public static let defaultCombo = KeyCombo(
        keyCode: KeyCodeMap.h,
        modifiers: controlModifier | optionModifier
    )

    public static func parse(_ raw: String) -> KeyCombo? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        var modifiers: UInt32 = 0

        // Compact form: ⌃⌥H
        while let first = text.first, let flag = KeyCodeMap.modifierSymbols[first] {
            modifiers |= flag
            text.removeFirst()
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Token form: ctrl+alt+h, cmd shift p
        let tokens = text
            .replacingOccurrences(of: "+", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { String($0).lowercased() }
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return nil }

        let keyToken: String
        if tokens.count == 1 {
            keyToken = tokens[0]
        } else {
            for token in tokens.dropLast() {
                switch token {
                case "ctrl", "control", "⌃":
                    modifiers |= controlModifier
                case "opt", "option", "alt", "⌥":
                    modifiers |= optionModifier
                case "shift", "⇧":
                    modifiers |= shiftModifier
                case "cmd", "command", "⌘":
                    modifiers |= commandModifier
                default:
                    return nil
                }
            }
            keyToken = tokens[tokens.count - 1]
        }

        guard let keyCode = KeyCodeMap.code(for: keyToken) else { return nil }
        let combo = KeyCombo(keyCode: keyCode, modifiers: modifiers)
        return combo.isValid ? combo : nil
    }
}

public enum KeyCodeMap {
    public static let h: UInt32 = 4
    public static let escape: UInt32 = 53

    private static let nameToCode: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33,
        "i": 34, "p": 35, "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39,
        "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "tab": 48, "space": 49, "`": 50, "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    private static let codeToDisplay: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
        34: "I", 35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
        42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
        50: "`", 51: "⌫", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    public static let modifierSymbols: [Character: UInt32] = [
        "⌃": KeyCombo.controlModifier,
        "⌥": KeyCombo.optionModifier,
        "⇧": KeyCombo.shiftModifier,
        "⌘": KeyCombo.commandModifier,
    ]

    public static func code(for name: String) -> UInt32? {
        nameToCode[name.lowercased()]
    }

    public static func displayName(for code: UInt32) -> String {
        codeToDisplay[code] ?? "?"
    }

    public static func name(for code: UInt32) -> String? {
        codeToDisplay[code]
    }
}
