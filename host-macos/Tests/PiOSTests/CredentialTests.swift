import XCTest
@testable import PiOSCore
@testable import PiOSMac

final class CredentialTests: XCTestCase {
    func testOnlyExplicitCredentialFieldsAreClassified() {
        for label in ["Username", "User name", "Benutzername", "Username or email", "Password", "Current password", "Enter your password", "Passwort:", "Neues Kennwort", "Password (required)"] {
            XCTAssertTrue(CredentialPolicy.isCredentialField(role: "AXTextField", labels: [label]), label)
        }
        XCTAssertTrue(CredentialPolicy.isCredentialField(role: "AXTextField", subrole: "AXSecureTextField"))
        XCTAssertTrue(CredentialPolicy.isCredentialField(role: "AXTextField", identifier: "login-username-field"))
        for label in ["", "Search", "Email", "Message", "Like", "Search password documentation", "Password policy notes", "Verification code", "Card number"] {
            XCTAssertFalse(CredentialPolicy.isCredentialField(role: "AXTextField", labels: [label]), label)
        }
        XCTAssertFalse(CredentialPolicy.isCredentialField(role: "AXButton", labels: ["Password"]))
        XCTAssertFalse(CredentialPolicy.isCredentialField(role: "AXTextField", subrole: nil))
    }
    func testDefaultBlockAndExplicitOverrideDoNotBlockOtherFields() throws {
        XCTAssertThrowsError(try CredentialPolicy.validate(isCredential: true, allowed: false)) {
            XCTAssertEqual(($0 as? DomainError)?.code, "credential_input_blocked")
        }
        XCTAssertNoThrow(try CredentialPolicy.validate(isCredential: false, allowed: false))
        XCTAssertNoThrow(try CredentialPolicy.validate(isCredential: true, allowed: true))
        XCTAssertThrowsError(try CredentialPolicy.validate(isCredential: true, allowed: false), "Turning the setting off restores field protection")
        XCTAssertThrowsError(try DeletionPolicy.validate(.click, args: .init(contextId: "test"), surface: .init(role: "AXButton", label: "Delete file")), "Credential opt-in does not affect deletion policy")
    }
    func testBrowserPermissionDefaultsToFalseAndTravelsAsHostMetadata() throws {
        var connection = BrowserConnection(processId: 12, port: 9222, initialURL: "https://example.com/", url: "https://example.com/", bounds: .init(x: 0, y: 0, width: 800, height: 600))
        XCTAssertFalse(connection.allowCredentialFields)
        connection.allowCredentialFields = true
        let decoded = try JSONDecoder().decode(BrowserConnection.self, from: JSONEncoder().encode(connection))
        XCTAssertTrue(decoded.allowCredentialFields)
    }
    func testGlobalSecureKeyboardEntryIsNotDisabledOrUsedAsAnInputVeto() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let native = try String(contentsOf: root.appendingPathComponent("Sources/PiOSMac/NativeInput.swift"), encoding: .utf8)
        XCTAssertFalse(native.contains("IsSecureEventInputEnabled("))
        XCTAssertFalse(native.contains("DisableSecureEventInput("))
        XCTAssertTrue(native.contains("CredentialFields.validate(element"))
        let point = try String(contentsOf: root.appendingPathComponent("Sources/PiOSMac/InputSurfaceInspector.swift"), encoding: .utf8)
        XCTAssertTrue(point.contains("CredentialFields.validateClick(element)"))
    }
}
