import Foundation

/// Field-local policy. The OS-wide Secure Keyboard Entry flag is not an input veto.
/// Only explicit username/password semantics qualify; values are never used to classify.
public enum CredentialPolicy {
    public static let preferenceKey = "allowCredentialFieldInput"
    public static let refusalCode = "credential_input_blocked"
    public static func isCredentialField(role: String, subrole: String? = nil, labels: [String] = [], identifier: String = "") -> Bool {
        guard ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) else { return false }
        if subrole == "AXSecureTextField" { return true }
        func normalized(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ":* ."))
        }
        let pattern = #"^(?:(?:enter|please enter|your|current|new|confirm|repeat|retype|account|login|ihr|dein|aktuelles|neues)\s+)*(?:user[ _-]?name|benutzername|nutzername|anmeldename|password|passwort|kennwort)(?:\s*(?:\((?:required|optional|erforderlich)\)|required|optional|bestatigen|wiederholen|(?:or|oder|/)\s*(?:email|e-mail|username)))?$"#
        if labels.contains(where: { $0.count <= 160 && normalized($0).range(of: pattern, options: .regularExpression) != nil }) { return true }
        let id = normalized(identifier)
        return id.range(of: #"(?:^|[-_])(?:username|user[-_]name|password|passwd|passwort|kennwort)(?:$|[-_])"#, options: .regularExpression) != nil
    }
    public static func validate(isCredential: Bool, allowed: Bool) throws {
        guard !isCredential || allowed else {
            throw DomainError(refusalCode, "This username/password field is blocked by pi-os. Enable ‘Allow input in username and password fields’ in pi-os Settings if you want to use it. Other fields and clicks remain available; do not disable macOS Secure Keyboard Entry.")
        }
    }
}
