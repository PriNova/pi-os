import AppKit
import ApplicationServices
import Carbon
import PiOSCore

struct ProcessFingerprint: Equatable {
    let uid: UInt32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let bundleID: String
}

enum NativeInputEvent {
    case move(Point), down(Point), up(Point)
    case key(UInt16, Bool, Set<String>)
    case unicode([UInt16], Bool)
    case scroll(Point, Double, Double)
}

protocol DesktopInputDriver {
    func inspect(_ target: WindowContext) throws -> Rect
    func focus(_ target: WindowContext) async throws
    func validateFocusAndSecurity(_ target: WindowContext, action: InputAction, arguments: InputArguments) throws
    func validateActionPoint(_ point: Point, target: WindowContext, action: InputAction) throws
    func validatePoint(_ point: Point, target: WindowContext) throws
    func keyCode(_ key: String, command: Bool) async throws -> UInt16
    /// Allocate before mutation. The returned closure must only post the prepared event.
    func prepare(_ event: NativeInputEvent, pid: pid_t) throws -> () -> Void
}

extension DesktopInputDriver {
    func validateActionPoint(_ point: Point, target: WindowContext, action: InputAction) throws {}
}

final class NativeDesktopDriver: DesktopInputDriver {
    let fingerprint: ProcessFingerprint
    var matchedWindow: AXUIElement?
    private var inspectedElement: AXUIElement?
    private var inspectedSurfaces: [InputSurface] = []
    init(fingerprint: ProcessFingerprint) { self.fingerprint = fingerprint }
    static func fingerprint(_ pid: pid_t) -> ProcessFingerprint? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              let app = NSRunningApplication(processIdentifier: pid), let bundleID = app.bundleIdentifier else { return nil }
        return ProcessFingerprint(uid: info.pbi_uid, startSeconds: info.pbi_start_tvsec,
                                  startMicroseconds: info.pbi_start_tvusec, bundleID: bundleID)
    }
    func inspect(_ target: WindowContext) throws -> Rect {
        let frame = try DesktopIdentity.revalidate(target)
        guard let current = Self.fingerprint(target.processId), current == fingerprint else {
            throw DomainError("target_gone", "The pinned process identity changed")
        }
        let desktop = FinderDesktop.isDesktop(target)
        try InputPolicy.validateIdentity(bundleID: current.bundleID, uid: current.uid, currentUID: getuid(),
                                         layer: desktop ? FinderDesktop.layer : 0, finderDesktop: desktop, desktopLayer: FinderDesktop.layer)
        guard AXIsProcessTrusted() else { throw DomainError("accessibility_denied", "Enable pi-os in Accessibility before computer control") }
        guard CGPreflightPostEventAccess() else { throw DomainError("input_permission_denied", "macOS has not allowed pi-os to post input events") }
        // Secure Keyboard Entry is an OS-wide keyboard-observation signal, not proof
        // that this destination is a credential field. Do not disable or blanket-gate it.
        return frame
    }
    func focus(_ target: WindowContext) async throws {
        matchedWindow = try await DesktopAX.focus(target)
        if FinderDesktop.isDesktop(target) { return }
        // Public vendor AX attribute used by Chromium/Electron to expose their accessibility tree.
        // It is not an input event; unsupported apps simply return attributeUnsupported.
        let app = AXUIElementCreateApplication(target.processId)
        AXUIElementSetMessagingTimeout(app, 0.05)
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
    func validateFocusAndSecurity(_ target: WindowContext, action: InputAction, arguments: InputArguments) throws {
        _ = try inspect(target)
        guard let window = matchedWindow, DesktopAX.exactFrontWindow(target, matched: window) else {
            throw DomainError("focus_failed", "Keyboard focus left the exact pinned window")
        }
        if FinderDesktop.isDesktop(target), ![.click, .scroll].contains(action) {
            try FinderDesktop.verifyKeyboardSelection(target, container: window)
        }
        let budget = DesktopAX.Budget(0.15)
        guard let element = DesktopAX.focusedElement(target, window: window, budget: budget),
              let role = budget.read(element, kAXRoleAttribute) as? String, role != kAXWindowRole else {
            throw DomainError("focus_unknown", "The focused control could not be inspected safely")
        }
        if ![.click, .scroll, .focus].contains(action) {
            // Reinspect metadata and the live setting before every keyboard chunk/chord
            // step. Missing labels alone are not evidence of a credential field.
            try CredentialFields.validate(element, budget: budget)
            if inspectedElement == nil || !CFEqual(inspectedElement!, element) {
                inspectedSurfaces = InputSurfaceInspector.surfaces(element, bundleID: fingerprint.bundleID)
                inspectedElement = element
            }
            try InputSurfaceInspector.validateFocused(action, arguments: arguments, surfaces: inspectedSurfaces)
        }
        // Avoid mixing synthetic input with keys or a drag currently held by the user.
        guard ![UInt16(54), 55, 56, 60, 58, 61, 59, 62].contains(where: { CGEventSource.keyState(.hidSystemState, key: $0) }),
              !CGEventSource.buttonState(.hidSystemState, button: .left),
              !CGEventSource.buttonState(.hidSystemState, button: .right) else {
            throw DomainError("busy", "Release held modifier keys or mouse buttons before computer control")
        }
    }
    func validateActionPoint(_ point: Point, target: WindowContext, action: InputAction) throws {
        if action == .click { try InputSurfaceInspector.validatePoint(point, target: target, bundleID: fingerprint.bundleID) }
    }
    private static let windowServerUID = getpwnam("_windowserver")?.pointee.pw_uid
    private static func isSystemCursor(_ info: [String: Any]) -> Bool {
        guard let level = info[kCGWindowLayer as String] as? Int,
              level == Int(CGWindowLevelForKey(.cursorWindow)), let pid = info[kCGWindowOwnerPID as String] as? pid_t else { return false }
        // proc_pidinfo denies cross-UID BSD info on macOS 27. KERN_PROC_PID is the
        // public metadata API for verifying this system process's UID (no task port).
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let status = mib.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, UInt32($0.count), &process, &size, nil, 0) }
        guard status == 0, size == MemoryLayout<kinfo_proc>.size else { return false }
        // proc_info.h: PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN (4096).
        // The compound macro is not imported by the macOS 27 Swift SDK.
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        return InputPolicy.isSystemCursor(level: level, cursorLevel: Int(CGWindowLevelForKey(.cursorWindow)),
            uid: process.kp_eproc.e_ucred.cr_uid, windowServerUID: windowServerUID, executable: String(cString: path))
    }
    func validatePoint(_ point: Point, target: WindowContext) throws {
        let top = DesktopIdentity.windows(includeDesktop: FinderDesktop.isDesktop(target)).first {
            ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0.01 && DesktopIdentity.bounds($0)?.contains(point) == true
                && !Self.isSystemCursor($0)
        }
        guard (top?[kCGWindowNumber as String] as? UInt32) == target.windowID,
              (top?[kCGWindowOwnerPID as String] as? Int32) == target.processId else {
            throw DomainError("focus_failed", "Another window covers the requested point; no click or scroll was posted")
        }
    }
    func keyCode(_ key: String, command: Bool) async throws -> UInt16 {
        try await KeyboardMapping.code(key, command: command)
    }
    func prepare(_ event: NativeInputEvent, pid: pid_t) throws -> () -> Void {
        let source = CGEventSource(stateID: .privateState)
        let cg: CGEvent?
        switch event {
        case .move(let p): cg = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: p.x, y: p.y), mouseButton: .left)
        case .down(let p): cg = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: p.x, y: p.y), mouseButton: .left)
        case .up(let p): cg = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: p.x, y: p.y), mouseButton: .left)
        case .key(let code, let down, let modifiers):
            cg = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            cg?.flags = KeyboardMapping.flags(modifiers)
        case .unicode(let units, let down):
            cg = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
            cg?.flags = []
            cg?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        case .scroll(let p, let dx, let dy):
            cg = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
                         wheel1: Int32((dy * 3).rounded()), wheel2: Int32((-dx * 3).rounded()), wheel3: 0)
            cg?.location = CGPoint(x: p.x, y: p.y)
        }
        guard let cg else { throw DomainError("input_failed", "macOS could not allocate an input event") }
        cg.setIntegerValueField(.eventSourceUserData, value: 0x50494F53)
        if case .down = event { cg.setIntegerValueField(.mouseEventClickState, value: 1) }
        if case .up = event { cg.setIntegerValueField(.mouseEventClickState, value: 1) }
        // Keyboard delivery can be PID-scoped. Mouse/scroll must pass through WindowServer
        // for real hit-testing and button tracking; validatePoint + exact focus run immediately
        // before these prepared events are posted. No fallback/retry after a posted event.
        switch event {
        case .move, .down, .up, .scroll: return { cg.post(tap: .cghidEventTap) }
        case .key, .unicode: return { cg.postToPid(pid) }
        }
    }
}

enum KeyboardMapping {
    static func code(_ key: String, command: Bool) async throws -> UInt16 {
        if let code = named[key] { return code }
        // Text Input Sources uses a main-queue-only cache on macOS 27. Keeping the
        // lookup on MainActor also avoids stale/off-thread layout access on older OSes.
        return try await MainActor.run { try layoutCode(key, command: command) }
    }
    @MainActor private static func layoutCode(_ key: String, command: Bool) throws -> UInt16 {
        guard key.count == 1, let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            throw DomainError("invalid_arguments", "The current keyboard layout cannot map this key")
        }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        let layout = UnsafeRawPointer(CFDataGetBytePtr(data)).assumingMemoryBound(to: UCKeyboardLayout.self)
        let keyboardType = UInt32(LMGetKbdType())
        for code in UInt16(0)..<128 {
            var dead: UInt32 = 0
            var count = 0
            var chars = [UniChar](repeating: 0, count: 8)
            let result = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), command ? UInt32(cmdKey >> 8) : 0,
                                        keyboardType, OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 8, &count, &chars)
            if result == noErr, String(utf16CodeUnits: chars, count: count).lowercased() == key { return code }
        }
        throw DomainError("invalid_arguments", "Key is unavailable in the current keyboard layout")
    }
    static let named: [String: UInt16] = ["enter": 36, "tab": 48, "space": 49, "escape": 53, "backspace": 51,
        "delete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "arrowleft": 123, "arrowright": 124, "arrowdown": 125, "arrowup": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111]
    static let modifiers: [(String, UInt16)] = [("ctrl", 59), ("alt", 58), ("shift", 56), ("cmd", 55)]
    static func flags(_ names: Set<String>) -> CGEventFlags {
        var result: CGEventFlags = []
        if names.contains("cmd") { result.insert(.maskCommand) }
        if names.contains("ctrl") { result.insert(.maskControl) }
        if names.contains("alt") { result.insert(.maskAlternate) }
        if names.contains("shift") { result.insert(.maskShift) }
        return result
    }
}

/// All rejection checks precede mutation. Callers serialize with OperationGate.
/// Any interruption after posting is deliberately reported as uncertain input_failed.
final class DesktopInputController {
    let driver: DesktopInputDriver
    let enabled: () -> Bool
    let typeInterval: Double
    init(driver: DesktopInputDriver, enabled: @escaping () -> Bool = { true }, typeInterval: Double = TextInput.intervalMilliseconds()) {
        self.driver = driver; self.enabled = enabled; self.typeInterval = typeInterval
    }
    func execute(_ action: InputAction, args: InputArguments, target: WindowContext,
                 transform: CaptureTransform?, coordinatesFresh: Bool = true, lease: ContextLease) async throws -> InputResult {
        var posted = 0
        func check() throws -> Rect {
            try Task.checkCancellation(); try lease.check()
            guard enabled() else { throw DomainError("control_disabled", "Computer control is disabled") }
            let frame = try driver.inspect(target)
            if action != .focus, let transform,
               (frame.width != transform.frame.width || frame.height != transform.frame.height) {
                throw DomainError("capture_stale", "The window resized; capture it again before input")
            }
            return frame
        }
        func beforeMutation() throws {
            _ = try check()
            try driver.validateFocusAndSecurity(target, action: action, arguments: args)
        }
        func pair(_ down: NativeInputEvent, _ up: NativeInputEvent) throws {
            let press = try driver.prepare(down, pid: target.processId)
            let release = try driver.prepare(up, pid: target.processId)
            try beforeMutation()
            press(); posted += 1
            // Release is never cancelled; it balances the already-posted press in the same PID.
            release(); posted += 1
        }
        do {
            try action.validate(args)
            let textStrokes = action == .typeText ? TextInput.strokes(args.text!) : []
            // The HTTP tool has a bounded 30-second deadline. Reject an oversized
            // paced request BEFORE focus/input rather than silently delivering a prefix.
            if Double(textStrokes.count) * typeInterval > 20_000 {
                throw DomainError("invalid_arguments", "Paced typing exceeds the per-call time budget. Split the text into smaller sequential calls.")
            }
            let initialFrame = try check()
            if action == .click || (action == .scroll && args.x != nil) {
                guard coordinatesFresh, let transform else { throw DomainError("capture_stale", "Capture the pinned window before coordinate input") }
                _ = try transform.screenPoint(Point(x: args.x!, y: args.y!), currentFrame: initialFrame)
            }
            try await driver.focus(target)
            _ = try check()
            if action == .focus { return InputResult(action: "focus", postedEvents: 0) }
            try beforeMutation()
            var point: Point?
            switch action {
            case .focus: break
            case .click, .scroll:
                let frame = try check()
                if let x = args.x, let y = args.y, let transform { point = try transform.screenPoint(Point(x: x, y: y), currentFrame: frame) }
                else { point = Point(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2) }
                try driver.validatePoint(point!, target: target)
                try driver.validateActionPoint(point!, target: target, action: action)
                if action == .click {
                    // Prepare all three events before posting anything.
                    let move = try driver.prepare(.move(point!), pid: target.processId)
                    let down = try driver.prepare(.down(point!), pid: target.processId)
                    let up = try driver.prepare(.up(point!), pid: target.processId)
                    try beforeMutation()
                    guard try check() == frame else { throw DomainError("capture_stale", "Window geometry changed while preparing the click") }
                    try driver.validatePoint(point!, target: target)
                    move(); posted += 1
                    try beforeMutation(); try driver.validatePoint(point!, target: target)
                    try driver.validateActionPoint(point!, target: target, action: action)
                    guard try check() == frame else { throw DomainError("capture_stale", "Window moved before click delivery") }
                    down(); posted += 1; up(); posted += 1
                } else {
                    let move = try driver.prepare(.move(point!), pid: target.processId)
                    let scroll = try driver.prepare(.scroll(point!, args.deltaX ?? 0, args.deltaY ?? 0), pid: target.processId)
                    try beforeMutation()
                    guard try check() == frame else { throw DomainError("capture_stale", "Window geometry changed while preparing the scroll") }
                    try driver.validatePoint(point!, target: target)
                    move(); posted += 1
                    try beforeMutation(); try driver.validatePoint(point!, target: target)
                    guard try check() == frame else { throw DomainError("capture_stale", "Window moved before scroll delivery") }
                    scroll(); posted += 1
                }
            case .typeText:
                for (index, stroke) in textStrokes.enumerated() {
                    switch stroke {
                    case .unicode(let units): try pair(.unicode(units, true), .unicode(units, false))
                    case .enter: try pair(.key(36, true, []), .key(36, false, []))
                    }
                    if index + 1 < textStrokes.count && typeInterval > 0 {
                        try await Task.sleep(nanoseconds: UInt64(typeInterval * 1_000_000))
                    }
                }
            case .pressKey:
                let code = try await driver.keyCode(args.key!.lowercased(), command: false)
                try pair(.key(code, true, []), .key(code, false, []))
            case .keyChord:
                let modifiers = Set(args.modifiers!)
                let code = try await driver.keyCode(args.key!.lowercased(), command: modifiers.contains("cmd"))
                var held: Set<String> = []
                var steps: [(press: () -> Void, release: () -> Void)] = []
                // Allocate every release first. A cancelled partial chord releases only keys
                // we actually pressed, in reverse order, without sending the primary key.
                for (name, key) in KeyboardMapping.modifiers where modifiers.contains(name) {
                    let release = try driver.prepare(.key(key, false, held), pid: target.processId)
                    held.insert(name)
                    steps.append((try driver.prepare(.key(key, true, held), pid: target.processId), release))
                }
                steps.append((try driver.prepare(.key(code, true, held), pid: target.processId),
                              try driver.prepare(.key(code, false, held), pid: target.processId)))
                var pressed = 0
                defer { for step in steps.prefix(pressed).reversed() { step.release(); posted += 1 } }
                for step in steps { try beforeMutation(); step.press(); posted += 1; pressed += 1 }
            }
            return InputResult(action: action.name, postedEvents: posted,
                               characters: action == .typeText ? args.text?.utf16.count : nil, x: args.x, y: args.y)
        } catch {
            if posted > 0 {
                let reason = (error as? DomainError)?.code ?? "native_error"
                throw DomainError("input_failed", "Input was interrupted (\(reason)) after events may have been posted. Do not retry this mutation.")
            }
            if error is CancellationError { throw DomainError("busy", "Input cancelled before posting") }
            throw error
        }
    }
}
