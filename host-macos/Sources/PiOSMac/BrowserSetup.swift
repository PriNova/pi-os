import AppKit
import PiOSCore

/// Local native setup only. Opening this sheet never starts Node or enumerates models.
@MainActor final class BrowserSetup: NSObject {
    private static let shared = BrowserSetup()
    static func present(changed: () -> Void = {}) {
        let alert = NSAlert()
        alert.messageText = "Connect to your existing Brave session"
        alert.informativeText = "In Brave, open brave://inspect/#remote-debugging and enable ‘Allow remote debugging for this browser instance’. Approve a connection prompt if Brave shows one. No restart or separate profile is needed.\n\nDebugging grants broad browser access, including cookies and site data. pi-os exposes only bounded page tools for the tab pinned by your shortcut; it does not export cookies. File deletion remains prohibited, but this is not a filesystem sandbox.\n\nCurrent pi-os setting: \(BrowserPin.requested ? "enabled" : "off"). Changes apply to new tasks. Disabling here disconnects tasks, but does not turn off Brave’s own debugging setting."
        alert.alertStyle = .warning
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 76))
        let label = NSTextField(labelWithString: "Local debugging port")
        label.frame = NSRect(x: 0, y: 48, width: 170, height: 22); accessory.addSubview(label)
        let port = NSTextField(string: String(BrowserPin.configuredPort))
        port.frame = NSRect(x: 176, y: 44, width: 90, height: 26)
        port.setAccessibilityLabel("Brave local debugging port"); accessory.addSubview(port)
        let open = NSButton(title: "Open Brave Setup…", target: shared, action: #selector(openSetup))
        open.bezelStyle = .rounded; open.frame = NSRect(x: 0, y: 4, width: 180, height: 32); accessory.addSubview(open)
        alert.accessoryView = accessory
        alert.addButton(withTitle: BrowserPin.requested ? "Save Connection" : "Enable Connection")
        alert.buttons[0].isEnabled = ControlAvailability.ready
        alert.addButton(withTitle: "Disable Connection")
        alert.addButton(withTitle: "Cancel")
        let result = alert.runModal()
        if result == .alertFirstButtonReturn {
            guard let value = Int(port.stringValue), (1...65535).contains(value) else {
                let error = NSAlert(); error.messageText = "Use a port between 1 and 65535"; error.runModal(); return
            }
            UserDefaults.standard.set(value, forKey: BrowserPolicy.portKey)
            UserDefaults.standard.set(true, forKey: BrowserPolicy.enabledKey)
            changed()
        } else if result == .alertSecondButtonReturn {
            UserDefaults.standard.set(false, forKey: BrowserPolicy.enabledKey)
            changed()
        }
    }
    @objc private func openSetup() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: BrowserPolicy.bundleID) else { NSSound.beep(); return }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([URL(string: "brave://inspect/#remote-debugging")!], withApplicationAt: app, configuration: config)
    }
}
