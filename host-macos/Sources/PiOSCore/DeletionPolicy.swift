import Foundation

/// Semantics of an inspected AX control. Never includes its editable value in diagnostics.
public struct InputSurface {
    public var role: String
    public var label: String
    public var identifier: String
    public var editableText: Bool
    public var terminal: Bool
    public var fileBrowser: Bool
    public init(role: String, label: String = "", identifier: String = "", editableText: Bool = false,
                terminal: Bool = false, fileBrowser: Bool = false) {
        self.role = role; self.label = label; self.identifier = identifier
        self.editableText = editableText; self.terminal = terminal; self.fileBrowser = fileBrowser
    }
}

/// Action-level guard, not an app denylist or a filesystem sandbox. Recognized destructive
/// controls/shortcuts/commands are rejected; opaque third-party code remains a separate risk.
public enum DeletionPolicy {
    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func destructiveControl(_ surface: InputSurface) -> Bool {
        guard ["AXButton", "AXMenuItem", "AXLink", "AXRadioButton"].contains(surface.role) else { return false }
        let label = normalized(surface.label).trimmingCharacters(in: CharacterSet(charactersIn: ".…!"))
        // Editing text is not deleting a file. Do not classify filenames or document text.
        if ["delete text", "delete word", "delete line", "text loschen", "wort loschen", "zeile loschen"].contains(label) { return false }
        let exact: Set<String> = ["delete", "delete permanently", "permanently delete", "move to trash", "move to bin",
            "empty trash", "empty bin", "delete file", "delete files", "delete selected files", "remove file", "remove files",
            "loschen", "datei loschen", "dateien loschen", "endgultig loschen", "sofort loschen", "in den papierkorb legen",
            "in den papierkorb verschieben", "papierkorb leeren"]
        if exact.contains(label) { return true }
        let identifiers = ["delete-file", "delete_file", "deletefile", "delete-selected", "move-to-trash", "empty-trash", "trash-selection", "remove-file"]
        let id = normalized(surface.identifier)
        return identifiers.contains { id.contains($0) }
    }
    public static func validate(_ action: InputAction, args: InputArguments, surface: InputSurface) throws {
        let activates = action == .click || ([.pressKey, .keyChord].contains(action) && ["enter", "space"].contains(args.key?.lowercased() ?? ""))
        if activates && destructiveControl(surface) { throw refusal() }
        let key = args.key?.lowercased() ?? ""
        let modifiers = Set(args.modifiers ?? [])
        if [.pressKey, .keyChord].contains(action), ["delete", "backspace"].contains(key) {
            if surface.fileBrowser && modifiers.isSuperset(of: ["cmd", "shift"]) { throw refusal() }
            if surface.fileBrowser && !surface.editableText { throw refusal() }
            // Cmd-Delete/Backspace outside an editable field is a common file/item removal shortcut.
            if modifiers.contains("cmd") && !surface.editableText { throw refusal() }
        }
        if action == .typeText, surface.terminal, let text = args.text, containsDestructiveCommand(text) { throw refusal() }
    }
    public static func containsDestructiveCommand(_ text: String) -> Bool {
        // Useful defense for recognized terminal surfaces, not a claim to parse every
        // language, shell alias, encoded script, remote command or application behavior.
        let patterns = [
            #"(?im)(?:^|[;&|`(\n])\s*(?:(?:sudo|command)\s+)*(?:[\w/.-]*/)?(?:rm|rmdir|unlink|trash|remove-item|del|erase)(?:\s|$)"#,
            #"(?i)\bfind\b[^\n]*\s-delete\b"#,
            #"(?i)\b(?:shutil\s*\.\s*rmtree|os\s*\.\s*(?:remove|unlink|rmdir)|fs\s*\.\s*(?:unlink|rm|rmdir)(?:Sync)?)\s*\("#,
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }
    private static func refusal() -> DomainError {
        DomainError("file_deletion_blocked", "Computer use cannot delete files, move them to Trash or empty Trash. Other normal actions remain available.")
    }
}
