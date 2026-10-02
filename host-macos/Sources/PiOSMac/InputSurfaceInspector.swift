import AppKit
import ApplicationServices
import PiOSCore

/// Reads semantic control metadata, never editable values, to distinguish actions from
/// application brands. AX is advisory UI metadata, not a sandbox for arbitrary code.
enum InputSurfaceInspector {
    private static let terminalBundles: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable", "com.github.wez.wezterm", "net.kovidgoyal.kitty", "org.alacritty", "com.cmuxterm.app"]
    static func surfaces(_ element: AXUIElement, bundleID: String) -> [InputSurface] {
        let budget = DesktopAX.Budget(0.08)
        var current: AXUIElement? = element, seen: [AXUIElement] = [], result: [InputSurface] = []
        var terminal = terminalBundles.contains(bundleID), files = bundleID == "com.apple.finder"
        for _ in 0..<8 {
            guard let node = current, Date() < budget.deadline, !seen.contains(where: { CFEqual($0, node) }) else { break }
            seen.append(node)
            guard let role = budget.read(node, kAXRoleAttribute) as? String else { break }
            if [kAXWindowRole, kAXApplicationRole].contains(role) { break }
            let identifier = budget.read(node, kAXIdentifierAttribute) as? String ?? ""
            let description = budget.read(node, kAXDescriptionAttribute) as? String ?? ""
            let title = budget.read(node, kAXTitleAttribute) as? String ?? ""
            let marker = (identifier + " " + description).lowercased()
            terminal = terminal || marker.contains("xterm") || marker.contains("terminal input") || marker.contains("terminal content") || description.lowercased() == "terminal"
            files = files || marker.contains("file-explorer") || marker.contains("file tree") || marker.contains("workbench.view.explorer")
            var editable = false
            if [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) {
                var settable: DarwinBoolean = false
                AXUIElementSetMessagingTimeout(node, 0.02)
                editable = AXUIElementIsAttributeSettable(node, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
            }
            result.append(InputSurface(role: role, label: title.isEmpty ? description : title,
                                       identifier: identifier, editableText: editable))
            current = budget.element(node, kAXParentAttribute)
        }
        for i in result.indices {
            result[i].terminal = terminal; result[i].fileBrowser = files
            if terminal && [kAXTextFieldRole, kAXTextAreaRole].contains(result[i].role) { result[i].editableText = true }
        }
        return result
    }
    static func validateFocused(_ action: InputAction, arguments: InputArguments, surfaces: [InputSurface]) throws {
        guard let first = surfaces.first else { return }
        // Keyboard deletion/commands depend on the receiving editor; do not replace its
        // editability with a noneditable ancestor's state.
        try DeletionPolicy.validate(action, args: arguments, surface: first)
        if [.pressKey, .keyChord].contains(action) && ["enter", "space"].contains(arguments.key?.lowercased() ?? "") {
            for surface in surfaces.dropFirst() {
                if DeletionPolicy.destructiveControl(surface) {
                    throw DomainError("file_deletion_blocked", "Computer use cannot activate a file-deletion control")
                }
            }
        }
    }
    static func validatePoint(_ point: Point, target: WindowContext, bundleID: String) throws {
        let app = AXUIElementCreateApplication(target.processId)
        AXUIElementSetMessagingTimeout(app, 0.04)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &element) == .success, let element else { return }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == target.processId else { return }
        try CredentialFields.validateClick(element)
        for surface in surfaces(element, bundleID: bundleID) {
            try DeletionPolicy.validate(.click, args: .init(contextId: ""), surface: surface)
        }
    }
}
