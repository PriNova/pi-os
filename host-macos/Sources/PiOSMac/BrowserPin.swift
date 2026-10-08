import AppKit
import ApplicationServices
import PiOSCore

/// Retained native tab identity, obtained BEFORE the prompt. A URL/title is not identity.
/// This contains AX objects and never crosses the JSON boundary.
public final class BrowserPin: @unchecked Sendable {
    let window: AXUIElement
    let group: AXUIElement
    let tab: AXUIElement
    let initialURL: String
    let port: Int
    private init(window: AXUIElement, group: AXUIElement, tab: AXUIElement, url: String, port: Int) {
        self.window = window; self.group = group; self.tab = tab; initialURL = url; self.port = port
    }
    public static var requested: Bool { UserDefaults.standard.bool(forKey: BrowserPolicy.enabledKey) }
    public static var configuredPort: Int {
        let value = UserDefaults.standard.integer(forKey: BrowserPolicy.portKey)
        return (1...65535).contains(value) ? value : 9222
    }
    static func children(_ element: AXUIElement, budget: DesktopAX.Budget) throws -> [AXUIElement] {
        guard budget.deadline > Date() else { throw unavailable() }
        AXUIElementSetMessagingTimeout(element, Float(min(0.03, budget.deadline.timeIntervalSinceNow)))
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success,
              count <= 256 else { throw unavailable() }
        if count == 0 { return [] }
        var array: CFArray?
        guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, count, &array) == .success,
              let children = array as? [AXUIElement], children.count == count else { throw unavailable() }
        return children
    }
    /// Search only browser chrome; never walk inside page content or browser toolbars.
    static func parts(_ window: AXUIElement, budget: DesktopAX.Budget) throws -> (AXUIElement, AXUIElement) {
        var queue: [(AXUIElement, Int)] = [(window, 0)], index = 0
        var groups: [AXUIElement] = [], pages: [AXUIElement] = []
        while index < queue.count {
            guard index < 256, budget.deadline > Date() else { throw unavailable() }
            let (node, depth) = queue[index]; index += 1
            guard let role = budget.read(node, kAXRoleAttribute) as? String else { throw unavailable() }
            if role == "AXWebArea" { pages.append(node); continue }
            if role == kAXTabGroupRole { groups.append(node); continue }
            if ![kAXWindowRole, kAXGroupRole, kAXSplitGroupRole, kAXScrollAreaRole].contains(role) { continue }
            guard depth < 12 else { throw unavailable() }
            let nodes = try children(node, budget: budget)
            guard queue.count + nodes.count <= 256 else { throw unavailable() }
            queue.append(contentsOf: nodes.map { ($0, depth + 1) })
        }
        guard groups.count == 1, pages.count == 1 else { throw unavailable() }
        return (groups[0], pages[0])
    }
    static func selectedTab(_ group: AXUIElement, budget: DesktopAX.Budget) throws -> AXUIElement {
        var selected: [AXUIElement] = []
        for tab in try children(group, budget: budget) {
            guard let role = budget.read(tab, kAXRoleAttribute) as? String,
                  role == kAXRadioButtonRole, budget.read(tab, kAXSubroleAttribute) as? String == "AXTabButton",
                  let value = budget.read(tab, kAXValueAttribute) as? Int, value == 0 || value == 1 else { throw unavailable() }
            if value == 1 { selected.append(tab) }
        }
        guard selected.count == 1 else { throw unavailable() }
        return selected[0]
    }
    static func url(_ page: AXUIElement, budget: DesktopAX.Budget) throws -> String {
        let value = budget.read(page, kAXURLAttribute)
        let text = (value as? URL)?.absoluteString ?? (value as? String) ?? ""
        guard !text.isEmpty else { throw DomainError("browser_stale", "The pinned page URL is not ready; take a fresh browser snapshot") }
        guard BrowserPolicy.validURL(text) else { throw DomainError("browser_page_unsupported", "Brave connection supports ordinary HTTP(S) pages, not browser settings, extensions or local files") }
        return text
    }
    public static func capture(_ snapshot: inout Snapshot) -> BrowserPin? {
        guard requested, let target = snapshot.targetWindow,
              NSRunningApplication(processIdentifier: target.processId)?.bundleIdentifier == BrowserPolicy.bundleID else { return nil }
        snapshot.browser = BrowserHint(pinned: false)
        guard AXIsProcessTrusted() else { return nil }
        let budget = DesktopAX.Budget(0.12)
        let app = AXUIElementCreateApplication(target.processId)
        AXUIElementSetMessagingTimeout(app, 0.02)
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        do {
            guard let window = budget.element(app, kAXFocusedWindowAttribute),
                  let frame = budget.frame(window), DesktopAX.sameFrame(frame, target.bounds) else { return nil }
            let (group, page) = try parts(window, budget: budget)
            let tab = try selectedTab(group, budget: budget)
            let url = try url(page, budget: budget)
            snapshot.browser?.pinned = true
            return BrowserPin(window: window, group: group, tab: tab, url: url, port: configuredPort)
        } catch { return nil }
    }
    func verify(_ target: WindowContext) throws -> BrowserConnection {
        guard Self.requested, Self.configuredPort == port else { throw DomainError("browser_disabled", "Brave connection settings changed; start a new task") }
        let frame = try DesktopIdentity.revalidate(target), budget = DesktopAX.Budget(0.3)
        let windowFrame = budget.frame(window)
        if ProcessInfo.processInfo.environment["PI_OS_BROWSER_DIAGNOSTICS"] == "1" {
            print("[browser pin] cg=\(frame) ax=\(String(describing: windowFrame))"); fflush(stdout)
        }
        guard let windowFrame, DesktopAX.sameFrame(windowFrame, frame) else { throw changed("window geometry") }
        guard let owner = budget.element(tab, kAXWindowAttribute), CFEqual(owner, window) else { throw changed("tab owning window") }
        guard CFEqual(tab, try Self.selectedTab(group, budget: budget)) else { throw changed("selected tab identity") }
        let currentGroup: AXUIElement, page: AXUIElement
        do { (currentGroup, page) = try Self.parts(window, budget: budget) }
        catch {
            // The retained tab is still selected, but Chromium temporarily removes
            // its web area while loading. Observation may retry; no action is sent.
            throw DomainError("browser_stale", "The pinned tab's page is loading. Take a fresh browser snapshot before acting.")
        }
        guard CFEqual(group, currentGroup) else { throw changed("tab strip identity") }
        return BrowserConnection(processId: target.processId, port: port, initialURL: initialURL,
                                 url: try Self.url(page, budget: budget), bounds: frame,
                                 allowCredentialFields: CredentialFields.allowed)
    }
    func focus(_ target: WindowContext) async throws {
        _ = try verify(target)
        var current = target
        current.title = DesktopAX.Budget(0.05).read(window, kAXTitleAttribute) as? String ?? ""
        let matched = try await DesktopAX.focus(current)
        guard CFEqual(matched, window) else { throw changed() }
        _ = try verify(target)
    }
    private static func unavailable() -> DomainError {
        DomainError("browser_tab_unknown", "Brave's selected tab could not be pinned safely. Show a normal page with the tab strip visible, then press the pi-os shortcut again.")
    }
    private func changed(_ reason: String = "focused window") -> DomainError { DomainError("browser_target_changed", "The pinned Brave \(reason) changed. Start a new task on the intended tab.") }
}
