import AppKit
import ApplicationServices
import PiOSCore

struct FinderAXNode: Equatable {
    let element: AXUIElement
    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
}

/// Bounded public AX reads only. No AppleScript, Apple Events or filesystem enumeration.
final class NativeFinderTree: FinderTreeReader {
    typealias Node = FinderAXNode
    let budget: DesktopAX.Budget
    private var failedBound = false
    var exhausted: Bool { failedBound || Date() >= budget.deadline }
    init(seconds: TimeInterval) { budget = DesktopAX.Budget(seconds) }
    func children(_ node: Node) -> [Node]? {
        guard case let .available(_, nodes) = array(node, attribute: kAXChildrenAttribute, limit: 128, requireComplete: true) else { return nil }
        return nodes
    }
    func parent(_ node: Node) -> Node? { budget.element(node.element, kAXParentAttribute).map(Node.init) }
    func role(_ node: Node) -> String? { budget.read(node.element, kAXRoleAttribute) as? String }
    func frame(_ node: Node) -> Rect? { budget.frame(node.element) }
    func owner(_ node: Node) -> Int32? {
        guard !exhausted else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(node.element, &pid) == .success ? pid : nil
    }
    func selection(_ node: Node, limit: Int) -> FinderSelectionRead<Node> {
        array(node, attribute: kAXSelectedChildrenAttribute, limit: limit, requireComplete: false)
    }
    private func array(_ node: Node, attribute: String, limit: Int, requireComplete: Bool) -> FinderSelectionRead<Node> {
        guard !exhausted else { return .unavailable }
        AXUIElementSetMessagingTimeout(node.element, Float(min(0.04, max(0.001, budget.deadline.timeIntervalSinceNow))))
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(node.element, attribute as CFString, &count) == .success, count >= 0 else { return .unavailable }
        if requireComplete && count > limit { failedBound = true; return .unavailable }
        if count == 0 { return .available(count: 0, nodes: []) }
        guard !exhausted else { return .unavailable }
        AXUIElementSetMessagingTimeout(node.element, Float(min(0.04, max(0.001, budget.deadline.timeIntervalSinceNow))))
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(node.element, attribute as CFString, 0, min(count, limit), &values) == .success,
              let elements = values as? [AXUIElement] else { return .unavailable }
        return .available(count: count, nodes: elements.map(Node.init))
    }
    func summary(_ node: Node) -> ElementSummary? {
        guard let role = role(node), !exhausted else { return nil }
        let name = (budget.read(node.element, kAXTitleAttribute) as? String)
            ?? (budget.read(node.element, kAXDescriptionAttribute) as? String)
        // AXValue is deliberately not read; selection items are not editable text fields.
        let rawURL = budget.read(node.element, kAXURLAttribute)
        let url = (rawURL as? URL) ?? (rawURL as? String).flatMap(URL.init(string:))
        return ElementSummary(name: name.map { String($0.prefix(512)) }, controlType: role,
                              bounds: frame(node), value: url?.isFileURL == true ? url?.path : nil)
    }
}

enum FinderDesktop {
    static let layer = Int(CGWindowLevelForKey(.desktopIconWindow))
    static func isDesktop(_ target: WindowContext) -> Bool { target.surface == FinderContextPolicy.desktopSurface }
    static func eligible(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.finder"
    }
    static func container(target: WindowContext, frame: Rect, reader: NativeFinderTree) -> FinderAXNode? {
        guard isDesktop(target), eligible(pid: target.processId) else { return nil }
        let desktopFrames = DesktopIdentity.windows(includeDesktop: true).filter {
            DesktopIdentity.finderDesktop($0) && ($0[kCGWindowOwnerPID as String] as? Int32) == target.processId
        }.compactMap(DesktopIdentity.bounds)
        return FinderContextPolicy.desktopContainer(reader: reader, application: FinderAXNode(element: AXUIElementCreateApplication(target.processId)),
            pid: target.processId, frame: frame, workArea: target.desktopWorkArea, desktopUnion: FinderContextPolicy.union(desktopFrames))
    }
    static func focused(target: WindowContext, container: FinderAXNode, reader: NativeFinderTree, requireAbsentWindow: Bool = true) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        guard let app = reader.budget.element(system, kAXFocusedApplicationAttribute),
              reader.owner(FinderAXNode(element: app)) == target.processId, !reader.exhausted else { return nil }
        AXUIElementSetMessagingTimeout(app, Float(min(0.04, max(0.001, reader.budget.deadline.timeIntervalSinceNow))))
        var focusedWindow: CFTypeRef?
        let windowStatus = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        // A normal Finder window must never receive desktop keyboard input. A failed
        // read is not evidence that the focused window is absent.
        guard (!requireAbsentWindow || windowStatus == .noValue || windowStatus == .attributeUnsupported
                || (windowStatus == .success && focusedWindow == nil)), !reader.exhausted,
              let element = reader.budget.element(system, kAXFocusedUIElementAttribute),
              FinderContextPolicy.isDescendant(reader: reader, node: FinderAXNode(element: element), of: container, pid: target.processId) else { return nil }
        return element
    }
    static func focusedAtPin(_ target: WindowContext) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let reader = NativeFinderTree(seconds: 0.015)
        guard let container = container(target: target, frame: target.bounds, reader: reader) else { return false }
        return focused(target: target, container: container, reader: reader, requireAbsentWindow: false) != nil && !reader.exhausted
    }
    /// Never close/hide windows or synthesize a system shortcut to reach the desktop.
    /// Activate Finder, then (if necessary) use a public, settable AX focus attribute on
    /// an unambiguous desktop container. Every path requires exact post-focus verification.
    static func focus(_ target: WindowContext) async throws -> AXUIElement {
        guard AXIsProcessTrusted() else { throw DomainError("accessibility_denied", "Accessibility is required for Finder desktop control") }
        let frame = try DesktopIdentity.revalidate(target)
        let reader = NativeFinderTree(seconds: 0.15)
        guard let container = container(target: target, frame: frame, reader: reader) else {
            throw DomainError("focus_failed", "The pinned Finder desktop cannot be matched unambiguously")
        }
        if focused(target: target, container: container, reader: reader) != nil { return container.element }
        var settable: DarwinBoolean = false
        AXUIElementSetMessagingTimeout(container.element, 0.05)
        let canSetFocus = AXUIElementIsAttributeSettable(container.element, kAXFocusedAttribute as CFString, &settable) == .success && settable.boolValue
        try Task.checkCancellation()
        let app = AXUIElementCreateApplication(target.processId)
        AXUIElementSetMessagingTimeout(app, 0.05)
        guard AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success else {
            throw DomainError("focus_failed", "Finder declined activation; no input was posted")
        }
        // Activation may restore the already-pinned desktop. Never accept restoration
        // of a different Finder window as success, and never use Show Desktop shortcuts.
        for _ in 0..<3 {
            try Task.checkCancellation()
            if let exact = try? verifyFocus(target), CFEqual(exact, container.element) { return exact }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        guard canSetFocus,
              AXUIElementSetAttributeValue(container.element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else {
            throw DomainError("focus_failed", "Finder cannot focus this desktop through public AX. Click the desktop and try a new task; no input was posted")
        }
        for _ in 0..<8 {
            try Task.checkCancellation()
            if let exact = try? verifyFocus(target), CFEqual(exact, container.element) { return exact }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw DomainError("focus_failed", "The exact pinned desktop did not receive focus; no input was posted")
    }
    static func verifyFocus(_ target: WindowContext) throws -> AXUIElement {
        guard AXIsProcessTrusted() else { throw DomainError("accessibility_denied", "Accessibility is required to verify the Finder desktop") }
        let frame = try DesktopIdentity.revalidate(target)
        let reader = NativeFinderTree(seconds: 0.15)
        guard let container = container(target: target, frame: frame, reader: reader),
              focused(target: target, container: container, reader: reader) != nil else {
            throw DomainError("focus_failed", "The exact Finder desktop is not focused or cannot be matched unambiguously; no input was posted")
        }
        return container.element
    }
    static func verifyKeyboardSelection(_ target: WindowContext, container: AXUIElement) throws {
        let frame = try DesktopIdentity.revalidate(target)
        let reader = NativeFinderTree(seconds: 0.15)
        guard FinderContextPolicy.keyboardSelectionIsWithin(reader: reader, container: FinderAXNode(element: container), pid: target.processId, frame: frame) else {
            throw DomainError("focus_unknown", "Finder's desktop selection is unavailable or spans outside the pinned display. Select an item on that desktop before keyboard input.")
        }
    }
    static func selection(_ target: WindowContext) -> FinderSelection? {
        guard AXIsProcessTrusted(), let frame = try? DesktopIdentity.revalidate(target) else { return nil }
        let reader = NativeFinderTree(seconds: 0.18)
        guard let container = container(target: target, frame: frame, reader: reader) else { return nil }
        return FinderContextPolicy.selected(reader: reader, container: container, pid: target.processId)
    }
    static func enrich(_ snapshot: inout Snapshot) {
        snapshot.selectedDesktopItems = nil; snapshot.selectedDesktopItemCount = nil; snapshot.selectedDesktopItemsTruncated = nil
        guard let target = snapshot.targetWindow, isDesktop(target), let selection = selection(target) else { return }
        snapshot.selectedDesktopItems = selection.items
        snapshot.selectedDesktopItemCount = selection.totalCount
        snapshot.selectedDesktopItemsTruncated = selection.truncated
    }
}
