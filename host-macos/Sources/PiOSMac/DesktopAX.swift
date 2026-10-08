import AppKit
import ApplicationServices
import PiOSCore

/// Only public AX attributes/actions. No private CGWindowID ↔ AX bridge.
public enum DesktopAX {
    final class Budget {
        let deadline: Date
        init(_ seconds: TimeInterval) { deadline = Date().addingTimeInterval(seconds) }
        func read(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            AXUIElementSetMessagingTimeout(element, Float(min(remaining, 0.08)))
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }
        func frame(_ element: AXUIElement) -> Rect? {
            guard let p = read(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
                  let s = read(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero, size = CGSize.zero
            guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
            return Rect(x: point.x, y: point.y, width: size.width, height: size.height)
        }
        func element(_ object: AXUIElement, _ name: String) -> AXUIElement? {
            guard let value = read(object, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
    }
    public static func sameFrame(_ a: Rect, _ b: Rect) -> Bool {
        abs(a.x - b.x) <= 0.5 && abs(a.y - b.y) <= 0.5 && abs(a.width - b.width) <= 0.5 && abs(a.height - b.height) <= 0.5
    }
    static func matchWindow(_ target: WindowContext, frame: Rect, budget: Budget) throws -> AXUIElement {
        let app = AXUIElementCreateApplication(target.processId)
        guard let windows = budget.read(app, kAXWindowsAttribute) as? [AXUIElement], windows.count <= 128 else {
            throw DomainError("focus_failed", "The target's accessibility windows are unavailable")
        }
        let matches = windows.filter { element in
            guard let bounds = budget.frame(element), sameFrame(bounds, frame) else { return false }
            if !target.title.isEmpty {
                return (budget.read(element, kAXTitleAttribute) as? String) == target.title
            }
            return true
        }
        guard matches.count == 1 else {
            throw DomainError("focus_failed", "Exact window match is missing or ambiguous; no input was posted")
        }
        return matches[0]
    }
    static func exactFrontWindow(_ target: WindowContext, matched: AXUIElement? = nil) -> Bool {
        if FinderDesktop.isDesktop(target) {
            guard let container = try? FinderDesktop.verifyFocus(target) else { return false }
            return matched == nil || CFEqual(container, matched!)
        }
        let budget = Budget(0.12)
        // NSWorkspace's cached frontmostApplication can lag on a worker queue. AX's
        // system-wide focused application is the authoritative keyboard recipient.
        guard let focusedApp = budget.element(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute) else { return false }
        var focusedPID: pid_t = 0
        guard AXUIElementGetPid(focusedApp, &focusedPID) == .success, focusedPID == target.processId,
              let first = DesktopIdentity.windows().first(where: { ($0[kCGWindowLayer as String] as? Int) == 0 }),
              (first[kCGWindowNumber as String] as? UInt32) == target.windowID,
              (first[kCGWindowOwnerPID as String] as? Int32) == target.processId,
              let frame = try? DesktopIdentity.revalidate(target) else { return false }
        let app = AXUIElementCreateApplication(target.processId)
        guard let focused = budget.element(app, kAXFocusedWindowAttribute),
              let bounds = budget.frame(focused), sameFrame(bounds, frame) else { return false }
        if let matched, !CFEqual(focused, matched) { return false }
        return true
    }
    /// Raising is never proof: CG front order AND the exact AX focused window must agree.
    /// This method posts no CGEvents and can be used independently as the M4 focus spike.
    public static func focus(_ target: WindowContext) async throws -> AXUIElement {
        if FinderDesktop.isDesktop(target) { return try await FinderDesktop.focus(target) }
        guard AXIsProcessTrusted() else { throw DomainError("accessibility_denied", "Enable pi-os in Accessibility before computer control") }
        let frame = try DesktopIdentity.revalidate(target)
        let budget = Budget(0.8)
        let matched = try matchWindow(target, frame: frame, budget: budget)
        if exactFrontWindow(target, matched: matched) { return matched }
        try Task.checkCancellation()
        let app = AXUIElementCreateApplication(target.processId)
        AXUIElementSetMessagingTimeout(app, 0.08)
        AXUIElementSetMessagingTimeout(matched, 0.08)
        guard AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success,
              AXUIElementPerformAction(matched, kAXRaiseAction as CFString) == .success else {
            throw DomainError("focus_failed", "macOS declined to raise the exact pinned window")
        }
        // Bounded verification only while a requested focus operation is active.
        for _ in 0..<12 {
            try Task.checkCancellation()
            _ = try DesktopIdentity.revalidate(target)
            if exactFrontWindow(target, matched: matched) { return matched }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        if ProcessInfo.processInfo.environment["PI_OS_FOCUS_DIAGNOSTICS"] == "1" {
            let first = DesktopIdentity.windows().first(where: { ($0[kCGWindowLayer as String] as? Int) == 0 })
            let focused = budget.element(app, kAXFocusedWindowAttribute)
            print("[focus probe] expected=\(target.processId)/\(target.hwnd) frontPID=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1) CG=\(first?[kCGWindowOwnerPID as String] ?? -1)/\(first?[kCGWindowNumber as String] ?? 0) AXequal=\(focused.map { CFEqual($0, matched) } ?? false)")
        }
        throw DomainError("focus_failed", "The exact pinned window did not become focused; no input was posted")
    }
    static func focusedElement(_ target: WindowContext, window: AXUIElement, budget: Budget) -> AXUIElement? {
        if FinderDesktop.isDesktop(target) {
            return FinderDesktop.focused(target: target, container: FinderAXNode(element: window), reader: NativeFinderTree(seconds: min(0.08, max(0, budget.deadline.timeIntervalSinceNow))))
        }
        // The per-app value can remain stale when a nonactivating panel takes keys.
        // Validate the system-wide recipient itself, then its PID and owning window.
        guard let focused = budget.element(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(focused, &pid) == .success, pid == target.processId,
              let owningWindow = budget.element(focused, kAXWindowAttribute), CFEqual(owningWindow, window) else { return nil }
        return focused
    }
    /// Nullable, privacy-bounded metadata. A secure value is never read, even for observation.
    static func summary(_ element: AXUIElement, budget: Budget) -> ElementSummary? {
        guard let role = budget.read(element, kAXRoleAttribute) as? String else { return nil }
        let subrole = budget.read(element, kAXSubroleAttribute) as? String
        // Permission to INPUT credentials never grants permission to READ their values.
        let secure = subrole == kAXSecureTextFieldSubrole || (role == kAXTextFieldRole && subrole == nil)
            || CredentialFields.identified(element, budget: budget)
        return ElementSummary(name: secure ? nil : (budget.read(element, kAXTitleAttribute) as? String).map { String($0.prefix(512)) },
                              controlType: role, bounds: budget.frame(element),
                              isEnabled: budget.read(element, kAXEnabledAttribute) as? Bool,
                              isKeyboardFocusable: budget.read(element, kAXFocusedAttribute) as? Bool,
                              value: secure ? nil : (budget.read(element, kAXValueAttribute) as? String).map { String($0.prefix(2000)) })
    }
    static func enrichWindowDocument(_ snapshot: inout Snapshot) {
        guard let target = snapshot.targetWindow, !FinderDesktop.isDesktop(target) else { return }
        snapshot.targetWindow?.documentPath = nil
        snapshot.targetWindow?.shellFolderPath = nil
        guard AXIsProcessTrusted() else { return }
        let budget = Budget(0.08)
        guard let window = try? matchWindow(target, frame: target.bounds, budget: budget),
              let document = budget.read(window, kAXDocumentAttribute) as? String,
              let url = URL(string: document), url.isFileURL else { return }
        if NSRunningApplication(processIdentifier: target.processId)?.bundleIdentifier == "com.apple.finder" {
            snapshot.targetWindow?.shellFolderPath = url.path
        } else { snapshot.targetWindow?.documentPath = url.path }
    }
    public static func refreshFocusedMetadata(_ snapshot: inout Snapshot) {
        if let point = CGEvent(source: nil)?.location { snapshot.cursor = Point(x: point.x, y: point.y) }
        let cursor = snapshot.cursor, monitors = snapshot.monitors
        snapshot.windowUnderCursor = DesktopIdentity.windows(includeDesktop: true).first {
            (DesktopIdentity.normal($0) || DesktopIdentity.finderDesktop($0)) && DesktopIdentity.bounds($0)?.contains(cursor) == true
        }.flatMap { DesktopIdentity.window($0, monitors: monitors) }
        snapshot.focusedElement = nil; snapshot.elementUnderCursor = nil
        guard AXIsProcessTrusted(), let target = snapshot.targetWindow else { return }
        if FinderDesktop.isDesktop(target) { FinderDesktop.enrich(&snapshot); return }
        let budget = Budget(0.2)
        guard let window = try? matchWindow(target, frame: target.bounds, budget: budget) else { return }
        if exactFrontWindow(target, matched: window), let focused = focusedElement(target, window: window, budget: budget) {
            snapshot.focusedElement = summary(focused, budget: budget)
        }
        let app = AXUIElementCreateApplication(target.processId)
        AXUIElementSetMessagingTimeout(app, 0.03)
        var under: AXUIElement?
        if target.bounds.contains(snapshot.cursor),
           AXUIElementCopyElementAtPosition(app, Float(snapshot.cursor.x), Float(snapshot.cursor.y), &under) == .success,
           let under, let owningWindow = budget.element(under, kAXWindowAttribute), CFEqual(owningWindow, window) {
            snapshot.elementUnderCursor = summary(under, budget: budget)
        }
    }
    /// Must run BEFORE the prompt steals key focus. The caller may omit it if the budget expires.
    public static func enrichBeforePanel(_ snapshot: inout Snapshot) {
        guard AXIsProcessTrusted(), let target = snapshot.targetWindow, !FinderDesktop.isDesktop(target) else { return }
        let budget = Budget(0.025)
        let app = AXUIElementCreateApplication(target.processId)
        guard let window = budget.element(app, kAXFocusedWindowAttribute),
              let frame = budget.frame(window), sameFrame(frame, target.bounds),
              let element = focusedElement(target, window: window, budget: budget) else { return }
        snapshot.focusedElement = summary(element, budget: budget)
    }
}
