import AppKit
import Carbon
import ShellCore

/// Public Carbon registration only: no event tap, global event monitor,
/// Accessibility check, or Input Monitoring permission request.
@MainActor
final class GlobalHotkey {
    private struct Registration {
        let reference: EventHotKeyRef
        let id: UInt32
    }
    private struct RegistrationError: LocalizedError {
        let operation: String
        let status: OSStatus
        var errorDescription: String? { "\(operation) failed (OSStatus \(status)). Use the menu to choose another hotkey." }
    }
    private static let signature: OSType = 0x70694F53 // piOS
    private var handler: EventHandlerRef?
    private var binding = HotkeyBinding<Registration>()
    private var nextID: UInt32 = 0
    private var activeID: UInt32?
    private(set) var cleanupWarning: String?
    var onPress: (() -> Void)?
    var current: Hotkey? { binding.hotkey }

    func apply(_ hotkey: Hotkey) throws {
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(
                GetApplicationEventTarget(), { _, event, context in
                    guard let event, let context else { return OSStatus(eventNotHandledErr) }
                    // Application event target dispatches on the main event loop.
                    return MainActor.assumeIsolated {
                        let service = Unmanaged<GlobalHotkey>.fromOpaque(context).takeUnretainedValue()
                        var id = EventHotKeyID()
                        let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                                       EventParamType(typeEventHotKeyID), nil,
                                                       MemoryLayout<EventHotKeyID>.size, nil, &id)
                        guard result == noErr, id.signature == GlobalHotkey.signature,
                              id.id == service.activeID else { return OSStatus(eventNotHandledErr) }
                        service.onPress?()
                        return noErr
                    }
                }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler
            )
            guard status == noErr else { throw RegistrationError(operation: "Hotkey event handler", status: status) }
        }
        try binding.replace(with: hotkey, register: { requested in
            nextID &+= 1
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: nextID)
            // Exclusive Carbon ownership is not a complete system-shortcut
            // collision check; actual delivery still requires manual testing.
            let status = RegisterEventHotKey(Self.keyCode(requested.key), Self.modifiers(requested.modifiers),
                                             id, GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
            guard status == noErr, let reference else {
                throw RegistrationError(operation: "Hotkey registration", status: status)
            }
            activeID = id.id
            return Registration(reference: reference, id: id.id)
        }, unregister: { registration in
            release(registration)
        })
    }

    func disable() {
        activeID = nil
        binding.clear { release($0) }
    }

    func stop() {
        disable()
        if let handler {
            let status = RemoveEventHandler(handler)
            if status != noErr { cleanupWarning = "Hotkey handler cleanup failed (OSStatus \(status)). Quit releases process resources." }
        }
        handler = nil
        onPress = nil
    }

    private func release(_ registration: Registration) {
        let status = UnregisterEventHotKey(registration.reference)
        if status != noErr {
            cleanupWarning = "Hotkey cleanup failed (OSStatus \(status)); an old shortcut may remain reserved until quit."
        }
    }

    private static func modifiers(_ value: Hotkey.Modifiers) -> UInt32 {
        var result: UInt32 = 0
        if value.contains(.control) { result |= UInt32(controlKey) }
        if value.contains(.option) { result |= UInt32(optionKey) }
        if value.contains(.shift) { result |= UInt32(shiftKey) }
        if value.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }

    private static func keyCode(_ key: Hotkey.Key) -> UInt32 {
        switch key {
        case .space: return UInt32(kVK_Space)
        case .function(let number):
            let codes = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
                         kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
            // Parser is the only public constructor of a binding.
            return UInt32(codes[number - 1])
        }
    }
}
