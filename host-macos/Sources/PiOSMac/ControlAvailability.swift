import Foundation
import ApplicationServices
import CoreGraphics
import Security

public enum ControlAvailability {
    public static let preferenceKey = "computerUseEnabled"
    /// Read-only remains an explicit user option. Input still needs real TCC grants.
    public static var requested: Bool { UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true }
    public static let stableSignature: Bool = {
        guard Bundle.main.bundleIdentifier == "dev.pi-os.mac", Bundle.main.bundleURL.pathExtension == "app" else { return false }
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let certificates = dict[kSecCodeInfoCertificates as String] as? [SecCertificate] else { return false }
        return !certificates.isEmpty
    }()
    public static var ready: Bool { requested && stableSignature && AXIsProcessTrusted() && CGPreflightPostEventAccess() }
    public static var explanation: String {
        if !requested { return "Read-only mode is selected in Settings." }
        if !stableSignature { return "Computer control needs a stable signed installation; ad-hoc development builds stay read-only." }
        if !AXIsProcessTrusted() { return "Enable pi-os in System Settings → Privacy & Security → Accessibility." }
        if !CGPreflightPostEventAccess() { return "macOS has not allowed input posting yet. Quit and reopen pi-os after granting Accessibility." }
        return "Clicking, typing, shortcuts and scrolling are available in the pinned window." }
}
