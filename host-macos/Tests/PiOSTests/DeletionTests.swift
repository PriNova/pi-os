import XCTest
@testable import PiOSCore

final class DeletionTests: XCTestCase {
    func testNormalAppsAreNotDeniedByBrand() {
        for bundle in ["com.stablyai.orca", "com.brave.Browser", "com.apple.Terminal", "com.openai.codex", "com.apple.systempreferences"] {
            XCTAssertNoThrow(try InputPolicy.validateIdentity(bundleID: bundle, uid: 501, currentUID: 501, layer: 0), bundle)
        }
        XCTAssertThrowsError(try InputPolicy.validateIdentity(bundleID: "dev.pi-os.mac", uid: 501, currentUID: 501, layer: 0))
        XCTAssertThrowsError(try InputPolicy.validateIdentity(bundleID: "com.stablyai.orca", uid: 0, currentUID: 501, layer: 0))
    }
    func testOrdinaryButtonsAndTrashNavigationAreAllowed() {
        for label in ["Like", "Unlike", "Save", "Send", "Open", "Copy", "Refresh", "Trash", "Papierkorb"] {
            XCTAssertNoThrow(try DeletionPolicy.validate(.click, args: .init(contextId: "x"), surface: .init(role: "AXButton", label: label)), label)
        }
        XCTAssertNoThrow(try DeletionPolicy.validate(.click, args: .init(contextId: "x"), surface: .init(role: "AXRow", label: "Delete me.txt", fileBrowser: true)))
    }
    func testDeletionButtonsMenusAndIdentifiersAreBlocked() {
        for label in ["Delete", "Delete permanently", "Move to Trash", "Empty Trash…", "Remove file", "Löschen", "In den Papierkorb legen", "Papierkorb leeren"] {
            for role in ["AXButton", "AXMenuItem"] {
                XCTAssertThrowsError(try DeletionPolicy.validate(.click, args: .init(contextId: "x"), surface: .init(role: role, label: label))) {
                    XCTAssertEqual(($0 as? DomainError)?.code, "file_deletion_blocked")
                }
            }
        }
        XCTAssertThrowsError(try DeletionPolicy.validate(.click, args: .init(contextId: "x"), surface: .init(role: "AXButton", identifier: "toolbar-delete-file")))
        XCTAssertThrowsError(try DeletionPolicy.validate(.pressKey, args: .init(contextId: "x", key: "enter"), surface: .init(role: "AXButton", label: "Delete")))
    }
    func testDeletingTextIsNotDeletingFiles() {
        let text = InputSurface(role: "AXTextArea", editableText: true)
        XCTAssertNoThrow(try DeletionPolicy.validate(.pressKey, args: .init(contextId: "x", key: "backspace"), surface: text))
        XCTAssertNoThrow(try DeletionPolicy.validate(.keyChord, args: .init(contextId: "x", key: "backspace", modifiers: ["cmd"]), surface: text))
        XCTAssertNoThrow(try DeletionPolicy.validate(.click, args: .init(contextId: "x"), surface: .init(role: "AXMenuItem", label: "Delete word")))
        XCTAssertNoThrow(try DeletionPolicy.validate(.typeText, args: .init(contextId: "x", text: "rm example.txt"), surface: text), "Editing code is not executing it")
        let files = InputSurface(role: "AXOutline", fileBrowser: true)
        XCTAssertThrowsError(try DeletionPolicy.validate(.pressKey, args: .init(contextId: "x", key: "delete"), surface: files))
        XCTAssertThrowsError(try DeletionPolicy.validate(.keyChord, args: .init(contextId: "x", key: "backspace", modifiers: ["cmd"]), surface: files))
    }
    func testRecognizedTerminalDeletionCommandsAreRejected() {
        let terminal = InputSurface(role: "AXTextArea", editableText: true, terminal: true)
        for command in ["rm file.txt", "sudo rm -rf folder", "/bin/rm -- file", "pwd; unlink file", "find . -name x -delete", "python -c 'import os; os.remove(\"x\")'"] {
            XCTAssertThrowsError(try DeletionPolicy.validate(.typeText, args: .init(contextId: "x", text: command), surface: terminal), command)
        }
        for command in ["pwd", "ls -la", "git status", "echo rm"] {
            XCTAssertNoThrow(try DeletionPolicy.validate(.typeText, args: .init(contextId: "x", text: command), surface: terminal), command)
        }
    }
    func testNormalAppLifecycleShortcutsAreNotGloballyBanned() {
        for key in ["q", "h", "m", "s", "w"] {
            XCTAssertNoThrow(try InputPolicy.validateChord(key: key, modifiers: ["cmd"]))
        }
        XCTAssertThrowsError(try InputPolicy.validateChord(key: "tab", modifiers: ["cmd"]))
    }
}
