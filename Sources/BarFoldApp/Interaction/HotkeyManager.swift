import BarFoldProtocol
import Carbon.HIToolbox
import Foundation

enum HotkeyRegistrationError: LocalizedError {
    case alreadyInUse(String)
    case registrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .alreadyInUse(let combo):
            return "\(combo) is already registered by another app"
        case .registrationFailed(let status):
            return "Carbon hotkey registration failed with status \(status)"
        }
    }
}

/// Carbon hotkeys need no Accessibility or Input Monitoring permission. The
/// manager owns exactly one hotkey and re-registers when the setting changes.
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onTrigger: () -> Void
    private let signature: OSType = 0x42466C64 // 'BFld'
    private let identifier: UInt32 = 1

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
        installHandler()
    }

    deinit {
        unregister()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    @discardableResult
    func register(_ combo: KeyCombo?) -> Result<Void, HotkeyRegistrationError> {
        unregister()
        guard let combo, combo.isValid else {
            return .success(())
        }

        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: identifier)
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr else {
            if status == eventHotKeyExistsErr {
                return .failure(.alreadyInUse(combo.displayString))
            }
            return .failure(.registrationFailed(status))
        }
        hotKeyRef = reference
        return .success(())
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.onTrigger()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }
}
