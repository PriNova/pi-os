import AppKit
import Carbon
import PiOSCore

public struct HotkeyChord: Equatable {
    public let keyCode: UInt32
    public let modifiers: UInt32
    public static let defaultValue = "Ctrl+Option+Cmd+Space"
    public init(_ raw: String) throws {
        let parts = raw.lowercased().split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, let key = parts.last, let code = Self.keys[key] else {
            throw DomainError("invalid_hotkey", "Use a modified key, for example \(Self.defaultValue)")
        }
        var mods: UInt32 = 0
        for part in parts.dropLast() {
            let bit: UInt32
            switch part {
            case "ctrl", "control": bit = UInt32(controlKey)
            case "alt", "option", "opt": bit = UInt32(optionKey)
            case "cmd", "command": bit = UInt32(cmdKey)
            case "shift": bit = UInt32(shiftKey)
            default: throw DomainError("invalid_hotkey", "Unknown hotkey modifier: \(part)")
            }
            guard mods & bit == 0 else { throw DomainError("invalid_hotkey", "Duplicate hotkey modifier") }
            mods |= bit
        }
        keyCode = code; modifiers = mods
    }
    // macOS virtual key codes are not contiguous, especially F1–F12.
    static let keys: [String: UInt32] = [
        "space": 49, "enter": 36, "tab": 48, "escape": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4,
        "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35,
        "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
    ]
    public func systemConflict() -> Bool {
        guard let domain = UserDefaults.standard.persistentDomain(forName: "com.apple.symbolichotkeys"),
              let keys = domain["AppleSymbolicHotKeys"] as? [String: [String: Any]] else { return false }
        return keys.values.contains { entry in
            guard (entry["enabled"] as? NSNumber)?.boolValue == true,
                  let value = entry["value"] as? [String: Any], let parameters = value["parameters"] as? [NSNumber], parameters.count >= 3 else { return false }
            return parameters[1].uint32Value == keyCode && parameters[2].uint32Value == modifiers
        }
    }
}

public final class GlobalHotkey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    public let systemConflict: Bool
    public init(chord: HotkeyChord, action: @escaping () -> Void) throws {
        self.action = action; systemConflict = chord.systemConflict()
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, data in
            guard let data else { return OSStatus(eventNotHandledErr) }
            Unmanaged<GlobalHotkey>.fromOpaque(data).takeUnretainedValue().action()
            return noErr
        }
        var status = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &type,
                                         Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw DomainError("hotkey_failed", "Carbon handler installation failed (\(status))") }
        status = RegisterEventHotKey(chord.keyCode, chord.modifiers, EventHotKeyID(signature: 0x50494F53, id: 1),
                                     GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr else {
            if let handler { RemoveEventHandler(handler); self.handler = nil }
            throw DomainError("hotkey_failed", status == eventHotKeyExistsErr ? "Hotkey is already registered by another application" : "Hotkey registration failed (\(status))")
        }
    }
    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}
