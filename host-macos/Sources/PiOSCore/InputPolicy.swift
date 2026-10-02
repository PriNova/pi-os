import Foundation

public struct InputArguments: Codable {
    public var contextId: String
    public var screenshotId: String?
    public var x: Double?
    public var y: Double?
    public var text: String?
    public var key: String?
    public var modifiers: [String]?
    public var deltaX: Double?
    public var deltaY: Double?
    public init(contextId: String, screenshotId: String? = nil, x: Double? = nil, y: Double? = nil, text: String? = nil,
                key: String? = nil, modifiers: [String]? = nil, deltaX: Double? = nil, deltaY: Double? = nil) {
        self.contextId = contextId; self.screenshotId = screenshotId; self.x = x; self.y = y; self.text = text; self.key = key
        self.modifiers = modifiers; self.deltaX = deltaX; self.deltaY = deltaY
    }
}

public enum InputAction: String, CaseIterable, Codable {
    case focus = "window.focus", click = "input.click", typeText = "input.typeText"
    case pressKey = "input.pressKey", keyChord = "input.keyChord", scroll = "input.scroll"
    public var name: String { String(rawValue.split(separator: ".").last!) }
    public func validate(_ args: InputArguments) throws {
        func finite(_ value: Double?) -> Bool { value?.isFinite == true }
        switch self {
        case .focus: break
        case .click:
            guard finite(args.x), finite(args.y) else { throw DomainError("invalid_arguments", "Click requires finite x and y") }
        case .typeText:
            guard let text = args.text, !text.isEmpty, text.utf16.count <= 20_000 else {
                throw DomainError("invalid_arguments", "Text must contain 1–20,000 UTF-16 units")
            }
        case .pressKey, .keyChord:
            guard let key = args.key?.lowercased(), InputPolicy.supportedKeys.contains(key) else {
                throw DomainError("invalid_arguments", "Unsupported key")
            }
            if self == .keyChord {
                guard let modifiers = args.modifiers, !modifiers.isEmpty,
                      Set(modifiers).count == modifiers.count,
                      modifiers.allSatisfy({ InputPolicy.modifiers.contains($0) }) else {
                    throw DomainError("invalid_arguments", "Use unique cmd, ctrl, alt and/or shift modifiers")
                }
                try InputPolicy.validateChord(key: key, modifiers: Set(modifiers))
            }
        case .scroll:
            let dx = args.deltaX ?? 0, dy = args.deltaY ?? 0
            guard dx.isFinite, dy.isFinite, dx != 0 || dy != 0, abs(dx) <= 100, abs(dy) <= 100,
                  (args.x == nil) == (args.y == nil), args.x == nil || (finite(args.x) && finite(args.y)) else {
                throw DomainError("invalid_arguments", "Scroll requires bounded nonzero deltas and both coordinates or neither")
            }
            guard dx == 0 || abs(dx * 3) >= 0.5, dy == 0 || abs(dy * 3) >= 0.5 else {
                throw DomainError("invalid_arguments", "Scroll movement is too small")
            }
        }
    }
}

public enum InputPolicy {
    public static let modifiers: Set<String> = ["cmd", "ctrl", "alt", "shift"]
    public static let supportedKeys = Set(["enter", "tab", "escape", "space", "backspace", "delete", "home", "end", "pageup", "pagedown",
        "arrowup", "arrowdown", "arrowleft", "arrowright"] + (1...12).map { "f\($0)" }
        + "abcdefghijklmnopqrstuvwxyz0123456789".map { String($0) })
    // App brands are not a safety boundary. Normal workbench/browser/editor/terminal
    // use is allowed; ownership, focus, secure fields and destructive actions are gated.
    // The host's own UI remains excluded to prevent recursive/self-permission control.
    public static let blockedBundles: Set<String> = ["dev.pi-os.mac"]
    public static func validateIdentity(bundleID: String?, uid: UInt32?, currentUID: UInt32, layer: Int,
                                        finderDesktop: Bool = false, desktopLayer: Int? = nil) throws {
        guard let uid, uid != 0, uid == currentUID else { throw DomainError("target_elevated", "Target ownership is unknown, root, or another user") }
        let normalWindow = layer == 0 && !finderDesktop
        let verifiedDesktopLayer = finderDesktop && bundleID == "com.apple.finder" && desktopLayer != nil && desktopLayer != 0 && layer == desktopLayer
        guard normalWindow || verifiedDesktopLayer, let bundleID, !bundleID.isEmpty, !blockedBundles.contains(bundleID) else {
            throw DomainError("policy_blocked", "Computer control is blocked for this application or window type")
        }
    }
    /// The OS cursor is visual decoration, not an input-receiving occluder. A matching
    /// level/name alone is not sufficient: require the dedicated system UID and binary.
    public static func isSystemCursor(level: Int, cursorLevel: Int, uid: UInt32?, windowServerUID: UInt32?, executable: String?) -> Bool {
        guard level == cursorLevel, let uid, let windowServerUID, uid == windowServerUID,
              let executable, executable.hasPrefix("/System/Library/"),
              URL(fileURLWithPath: executable).lastPathComponent == "WindowServer" else { return false }
        return true
    }
    public static func validateChord(key: String, modifiers: Set<String>) throws {
        let commandEscape = modifiers.contains("cmd") && ["tab", "space"].contains(key)
        let forceQuit = key == "escape" && modifiers.isSuperset(of: ["cmd", "alt"])
        let spaces = modifiers.contains("ctrl") && ["arrowup", "arrowdown", "arrowleft", "arrowright"].contains(key)
        guard !commandEscape && !forceQuit && !spaces else {
            throw DomainError("policy_blocked", "This system shortcut can escape the pinned window")
        }
    }
    /// Chunk without splitting surrogate pairs. CGEvent Unicode payloads stay small.
    public static func unicodeChunks(_ text: String, limit: Int = 20) -> [[UInt16]] {
        let units = Array(text.utf16)
        var result: [[UInt16]] = [], start = 0
        while start < units.count {
            var end = min(start + max(2, limit), units.count)
            if end < units.count, (0xD800...0xDBFF).contains(units[end - 1]) { end -= 1 }
            result.append(Array(units[start..<end])); start = end
        }
        return result
    }
}

public struct InputResult: Codable, Equatable {
    public var action: String
    public var postedEvents: Int
    public var characters: Int?
    public var x: Double?
    public var y: Double?
    public init(action: String, postedEvents: Int, characters: Int? = nil, x: Double? = nil, y: Double? = nil) {
        self.action = action; self.postedEvents = postedEvents; self.characters = characters; self.x = x; self.y = y
    }
}

public struct InputBudget {
    public private(set) var actions = 0
    public private(set) var characters = 0
    public init() {}
    public mutating func reserve(_ action: InputAction, arguments: InputArguments) throws {
        let count = action == .typeText ? arguments.text?.utf16.count ?? 0 : 0
        guard actions < 200, characters + count <= 100_000 else { throw DomainError("budget_exceeded", "Desktop task input budget reached; start a new task") }
        actions += 1; characters += count
    }
}
