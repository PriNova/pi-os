import AppKit
import ShellCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    private var statusItem: NSStatusItem?
    private let hotkeyStatusItem = NSMenuItem(title: "Hotkey not registered", action: nil, keyEquivalent: "")
    private let hotkey = GlobalHotkey()
    private let demo = DemoController()
    private let settings = ShellPanel(title: "pi-os — session hotkey")
    private var hotkeyField: NSTextField?
    private var hotkeyMessage: NSTextField?
    private var statusMessage = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installEditMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "pi-os"
        item.button?.toolTip = "Experimental macOS native-shell demonstration — no agent connected"
        item.button?.setAccessibilityLabel("pi-os experimental native shell")
        let menu = NSMenu()
        menu.autoenablesItems = false
        let title = NSMenuItem(title: "Experimental native shell · no agent", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        add("Open demonstration…", action: #selector(openDemo), to: menu)
        add("Capabilities / unsupported…", action: #selector(showUnsupported), to: menu)
        menu.addItem(.separator())
        hotkeyStatusItem.isEnabled = false
        menu.addItem(hotkeyStatusItem)
        add("Configure hotkey…", action: #selector(configureHotkey), to: menu)
        add("Disable hotkey", action: #selector(disableHotkey), to: menu)
        menu.addItem(.separator())
        add("Close / cancel demonstration", action: #selector(closeDemo), to: menu)
        add("Quit pi-os", action: #selector(quit), to: menu)
        item.menu = menu
        statusItem = item
        hotkey.onPress = { [weak self] in self?.openDemo() }
        settings.onEscape = { [weak self] in self?.closeSettings() }
        demo.onPresentationFailure = { [weak self] in
            self?.setStatus("Display unavailable; demonstration closed. Try again from the menu.")
        }
        let requested = ProcessInfo.processInfo.environment["PI_OS_HOTKEY"] ?? Hotkey.defaultBinding.description
        do {
            try hotkey.apply(Hotkey.parse(requested))
            showRegistrationStatus()
        } catch {
            // No silent fallback: a failed override must not reserve a different key.
            setStatus("Hotkey disabled. \(error.localizedDescription)")
        }
        // Deliberately no startup window, activation, permission check or dialog.
    }

    private func add(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func openDemo() {
        closeSettings()
        demo.openPrompt()
    }
    @objc private func showUnsupported() {
        closeSettings()
        demo.showUnsupported()
    }
    @objc private func closeDemo() { demo.close() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func configureHotkey() {
        // Settings are session-only and must not discard an unsent demo draft.
        let field = NSTextField(string: hotkey.current?.description ?? Hotkey.defaultBinding.description)
        field.setAccessibilityLabel("Global hotkey")
        field.target = self
        field.action = #selector(applyHotkey)
        field.delegate = self
        let message = UI.label(statusMessage)
        hotkeyField = field
        hotkeyMessage = message
        settings.resetPlacement()
        if !settings.present(views: [
            UI.label("pi-os · Configure hotkey", heading: true),
            UI.label("Session only; not saved. Use Ctrl/Alt/Shift/Cmd plus Space or F1–F12. Example: Ctrl+Shift+F9."),
            field, message,
            UI.row([UI.button("Apply", target: self, action: #selector(applyHotkey)),
                    UI.button("Close", target: self, action: #selector(closeSettings))]),
            UI.label("System shortcuts, Fn/media-key settings and other apps may prevent delivery. No permissions are requested.")
        ], size: CGSize(width: 540, height: 330), takeKey: true, firstResponder: field) {
            closeSettings()
            setStatus("Display unavailable; use PI_OS_HOTKEY on the next launch.")
        }
    }

    @objc private func applyHotkey() {
        guard let hotkeyField else { return }
        do {
            try hotkey.apply(Hotkey.parse(hotkeyField.stringValue))
            showRegistrationStatus()
            hotkeyField.stringValue = hotkey.current?.description ?? ""
        } catch {
            setStatus("\(error.localizedDescription) Previous binding unchanged.")
        }
    }
    @objc private func disableHotkey() {
        hotkey.disable()
        showRegistrationStatus()
    }
    @objc private func closeSettings() {
        hotkeyField?.stringValue = ""
        hotkeyField = nil
        hotkeyMessage = nil
        settings.orderOut(nil)
        settings.contentView = nil
    }
    private func showRegistrationStatus() {
        let binding = hotkey.current.map { "Hotkey registered: \($0). Delivery requires manual verification." }
            ?? "Hotkey disabled; the menu remains available."
        setStatus(binding + (hotkey.cleanupWarning.map { " \($0)" } ?? ""))
    }
    private func setStatus(_ message: String) {
        statusMessage = message
        hotkeyStatusItem.title = message
        hotkeyStatusItem.toolTip = message
        hotkeyMessage?.stringValue = message
    }

    func applicationWillTerminate(_ notification: Notification) {
        demo.close()
        closeSettings()
        hotkey.stop()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            closeSettings()
            return true
        }
        return false
    }

    private func installEditMenu() {
        // Standard, explicitly user-initiated editing only; no automatic copy.
        let main = NSMenu()
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        for (title, selector, key) in [
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a")
        ] {
            edit.addItem(NSMenuItem(title: title, action: selector, keyEquivalent: key))
        }
        item.submenu = edit
        main.addItem(item)
        NSApp.mainMenu = main
    }
}
