import AppKit
import ApplicationServices
import PiOSCore

/// Native field semantics only, never AXValue or a guess from the application's brand.
enum CredentialFields {
    static var allowed: Bool { UserDefaults.standard.bool(forKey: CredentialPolicy.preferenceKey) }
    static func identified(_ element: AXUIElement, budget: DesktopAX.Budget) -> Bool {
        guard let role = budget.read(element, kAXRoleAttribute) as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"].contains(role) else { return false }
        let subrole = budget.read(element, kAXSubroleAttribute) as? String
        if subrole == kAXSecureTextFieldSubrole { return true }
        var labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute].compactMap {
            budget.read(element, $0) as? String
        }
        if let label = budget.element(element, kAXTitleUIElementAttribute),
           let title = budget.read(label, kAXTitleAttribute) as? String { labels.append(title) }
        return CredentialPolicy.isCredentialField(role: role, subrole: subrole, labels: labels,
            identifier: budget.read(element, kAXIdentifierAttribute) as? String ?? "")
    }
    static func validate(_ element: AXUIElement, budget: DesktopAX.Budget) throws {
        try CredentialPolicy.validate(isCredential: identified(element, budget: budget), allowed: allowed)
    }
    /// Clicks are checked at the destination, not at a previously focused password field.
    static func validateClick(_ element: AXUIElement) throws {
        let budget = DesktopAX.Budget(0.08)
        var current: AXUIElement? = element
        for _ in 0..<4 {
            guard let node = current, Date() < budget.deadline else { break }
            let role = budget.read(node, kAXRoleAttribute) as? String
            if role == kAXWindowRole || role == kAXApplicationRole { break }
            try validate(node, budget: budget)
            current = budget.element(node, kAXParentAttribute)
        }
    }
    @MainActor static func confirmEnable() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Allow username and password input?"
        alert.informativeText = "pi-os will be allowed to type into clearly identified username and password fields in your chosen target. This does not read saved passwords or disable macOS security. Field values remain omitted from text snapshots.\n\nText you give the agent can be sent to your selected model provider and handled by trusted extensions. Only provide credentials when you intend that exposure. You can turn this permission off at any time; changing it cancels the current task."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Allow Credential Input")
        alert.addButton(withTitle: "Keep Fields Blocked")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
