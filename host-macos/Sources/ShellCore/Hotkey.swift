import Foundation

public struct Hotkey: Equatable, Sendable, CustomStringConvertible {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let control = Self(rawValue: 1 << 0)
        public static let option = Self(rawValue: 1 << 1)
        public static let shift = Self(rawValue: 1 << 2)
        public static let command = Self(rawValue: 1 << 3)
    }

    public enum Key: Equatable, Sendable {
        case space
        case function(Int)
    }

    public enum ParseError: Error, Equatable, LocalizedError {
        case invalidFormat, unknownModifier, duplicateModifier, missingModifier, unsupportedKey
        public var errorDescription: String? {
            switch self {
            case .invalidFormat: "Use modifiers plus Space or F1–F12, for example Ctrl+Alt+Space."
            case .unknownModifier: "Supported modifiers: Ctrl, Alt/Option, Shift, Cmd/Command."
            case .duplicateModifier: "Each modifier may appear only once (including aliases)."
            case .missingModifier: "Include at least one modifier to avoid capturing an ordinary key."
            case .unsupportedKey: "This foundation supports Space or F1–F12 only, not layout-dependent letters."
            }
        }
    }

    public let modifiers: Modifiers
    public let key: Key
    public static let defaultBinding = Hotkey(modifiers: [.control, .option], key: .space)

    public static func parse(_ text: String) throws -> Self {
        let parts = text.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard parts.allSatisfy({ !$0.isEmpty }) else { throw ParseError.invalidFormat }
        guard parts.count > 1 else { throw ParseError.missingModifier }
        var modifiers: Modifiers = []
        for part in parts.dropLast() {
            let modifier: Modifiers
            switch part {
            case "ctrl", "control": modifier = .control
            case "alt", "option", "opt": modifier = .option
            case "shift": modifier = .shift
            case "cmd", "command": modifier = .command
            default: throw ParseError.unknownModifier
            }
            guard !modifiers.contains(modifier) else { throw ParseError.duplicateModifier }
            modifiers.insert(modifier)
        }
        let key: Key
        if parts.last == "space" {
            key = .space
        } else if let last = parts.last, last.hasPrefix("f"),
                  let number = Int(last.dropFirst()), (1...12).contains(number), last == "f\(number)" {
            key = .function(number)
        } else { throw ParseError.unsupportedKey }
        return Self(modifiers: modifiers, key: key)
    }

    public var description: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.option) { parts.append("Alt") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.command) { parts.append("Cmd") }
        switch key {
        case .space: parts.append("Space")
        case .function(let n): parts.append("F\(n)")
        }
        return parts.joined(separator: "+")
    }
}

/// Register the replacement before releasing a working binding. Pure helper
/// permits rollback tests without registering a key or starting AppKit.
public struct HotkeyBinding<Token> {
    public private(set) var hotkey: Hotkey?
    private var token: Token?
    public init() {}

    @discardableResult
    public mutating func replace(
        with newHotkey: Hotkey,
        register: (Hotkey) throws -> Token,
        unregister: (Token) -> Void
    ) rethrows -> Bool {
        guard newHotkey != hotkey else { return false }
        let newToken = try register(newHotkey)
        let previous = token
        token = newToken
        hotkey = newHotkey
        if let previous { unregister(previous) }
        return true
    }

    public mutating func clear(unregister: (Token) -> Void) {
        if let token { unregister(token) }
        token = nil
        hotkey = nil
    }
}
