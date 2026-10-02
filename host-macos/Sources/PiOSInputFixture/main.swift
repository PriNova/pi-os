import AppKit
import PiOSCore

/// Disposable receiving app. No permissions, network, agent, or event injection.
/// The test parent alone owns stdin; EOF terminates this fixture.
final class ScrollContent: NSView { override var isFlipped: Bool { true } }
final class Fixture: NSObject, NSApplicationDelegate {
    var windows: [String: NSWindow] = [:]
    var fields: [String: NSTextField] = [:]
    var passwords: [String: NSSecureTextField] = [:]
    var usernames: [String: NSTextField] = [:]
    var multiline: [String: NSTextView] = [:]
    var multilineScrolls: [String: NSScrollView] = [:]
    var clicks: [String: Int] = [:]
    var saved: [String: Int] = [:]
    var buttons: [String: NSButton] = [:]
    var likes: [String: NSButton] = [:]
    var deletions: [String: NSButton] = [:]
    var liked: [String: Bool] = [:]
    var deletionAttempts: [String: Int] = [:]
    var scrolls: [String: NSScrollView] = [:]
    var ready: String { CommandLine.arguments[1] }
    var buffer = Data()
    var receivedEvents = 0
    var setupComplete = false
    var eventMonitor: Any?
    func applicationDidFinishLaunching(_ notification: Notification) {
        for (index, name) in ["A", "B"].enumerated() {
            let w = NSWindow(contentRect: NSRect(x: 140 + index * 400, y: 240, width: 360, height: 300),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "pi-os input fixture " + name; w.isReleasedWhenClosed = false
            let text = NSTextField(string: "original-" + name)
            text.frame = NSRect(x: 24, y: 200, width: 300, height: 28)
            text.setAccessibilityIdentifier("fixture-text-" + name)
            w.contentView!.addSubview(text)
            let multi = NSTextView(frame: NSRect(x: 0, y: 0, width: 310, height: 120))
            multi.isRichText = false; multi.isAutomaticQuoteSubstitutionEnabled = false
            multi.isAutomaticDashSubstitutionEnabled = false
            multi.setAccessibilityLabel("Multiline fixture text")
            let multiScroll = NSScrollView(frame: NSRect(x: 24, y: 180, width: 310, height: 90))
            multiScroll.documentView = multi; multiScroll.hasVerticalScroller = true; multiScroll.isHidden = true
            multiline[name] = multi; multilineScrolls[name] = multiScroll
            // Add last when activated so only the explicit multiline phase covers other controls.
            let username = NSTextField(string: "fixture-user")
            username.frame = NSRect(x: 24, y: 172, width: 300, height: 24)
            username.setAccessibilityLabel("Username"); username.setAccessibilityIdentifier("username")
            w.contentView!.addSubview(username); usernames[name] = username
            let secure = NSSecureTextField(string: "fixture-secret")
            secure.frame = NSRect(x: 24, y: 140, width: 300, height: 28)
            secure.placeholderString = "Password"
            w.contentView!.addSubview(secure); passwords[name] = secure
            let button = NSButton(title: "Click counter " + name, target: self, action: #selector(clicked(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(name)
            button.frame = NSRect(x: 24, y: 70, width: 180, height: 32)
            w.contentView!.addSubview(button)
            let like = NSButton(title: "Like", target: self, action: #selector(toggleLike(_:)))
            like.identifier = NSUserInterfaceItemIdentifier(name); like.frame = NSRect(x: 24, y: 20, width: 80, height: 32)
            w.contentView!.addSubview(like); likes[name] = like; liked[name] = false
            let deletion = NSButton(title: "Delete file", target: self, action: #selector(simulatedDelete(_:)))
            deletion.identifier = NSUserInterfaceItemIdentifier("fixture-delete-file-" + name)
            deletion.frame = NSRect(x: 108, y: 20, width: 102, height: 32)
            w.contentView!.addSubview(deletion); deletions[name] = deletion; deletionAttempts[name] = 0
            let scroll = NSScrollView(frame: NSRect(x: 220, y: 16, width: 110, height: 70))
            let page = ScrollContent(frame: NSRect(x: 0, y: 0, width: 100, height: 700))
            for row in 0..<20 {
                let label = NSTextField(labelWithString: "Row \(row)")
                label.frame = NSRect(x: 8, y: row * 30, width: 90, height: 22); page.addSubview(label)
            }
            scroll.documentView = page; scroll.hasVerticalScroller = true
            w.contentView!.addSubview(scroll); scrolls[name] = scroll
            windows[name] = w; fields[name] = text; clicks[name] = 0; saved[name] = 0; buttons[name] = button
            w.makeKeyAndOrderFront(nil); w.makeFirstResponder(text)
        }
        let menu = NSMenu()
        let file = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let save = NSMenuItem(title: "Save", action: #selector(saveDocument), keyEquivalent: "s")
        save.target = self; submenu.addItem(save); file.submenu = submenu; menu.addItem(file)
        NSApp.mainMenu = menu
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp]) { [weak self] event in
            if [.keyDown, .leftMouseDown].contains(event.type), event.cgEvent?.getIntegerValueField(.eventSourceUserData) != 0x50494F53 {
                let setupModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
                if self?.setupComplete == false, event.type == .keyDown, event.keyCode == 49,
                   event.modifierFlags.intersection(setupModifiers) == setupModifiers {
                    // The test's dedicated Carbon shortcut can also reach AppKit during
                    // activation. Swallow ONLY that setup chord, never insert its Space.
                    return nil
                }
                // Never collect incidental user typing in a test artifact. Stop the fixture
                // immediately if the user interacts with it during an automated run.
                fputs("Fixture stopped: external input detected; rerun when the desktop is idle.\n", stderr)
                NSApp.terminate(nil)
                return nil
            }
            self?.receivedEvents += 1
            return event
        }
        NSApp.activate()
        emitState()
        FileHandle.standardInput.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                guard let self else { return }
                if data.isEmpty { NSApp.terminate(nil); return }
                self.buffer.append(data)
                while let end = self.buffer.firstIndex(of: 10) {
                    let line = self.buffer[..<end]; self.buffer.removeSubrange(...end)
                    if let command = try? JSONSerialization.jsonObject(with: line) as? [String: String] {
                        autoreleasepool { self.command(command) }
                    }
                }
            }
        }
    }
    @objc func clicked(_ sender: NSButton) {
        let name = sender.identifier!.rawValue
        clicks[name, default: 0] += 1; emitState()
    }
    @objc func toggleLike(_ sender: NSButton) {
        let name = sender.identifier!.rawValue
        liked[name] = !(liked[name] ?? false)
        sender.title = liked[name] == true ? "Unlike" : "Like"
        emitState()
    }
    @objc func simulatedDelete(_ sender: NSButton) {
        let name = String(sender.identifier!.rawValue.suffix(1))
        deletionAttempts[name, default: 0] += 1
        // Deliberately no filesystem operation. A nonzero counter fails the guard test.
        emitState()
    }
    @objc func saveDocument() {
        guard let name = windows.first(where: { $0.value == NSApp.keyWindow })?.key else { return }
        saved[name, default: 0] += 1
        let file = URL(fileURLWithPath: ready).deletingLastPathComponent().appendingPathComponent("window-\(name).saved.txt")
        try? fieldValue(name).write(to: file, atomically: true, encoding: .utf8)
        emitState()
    }
    func command(_ command: [String: String]) {
        let name = command["window"] ?? "A"
        guard let w = windows[name] else { return }
        switch command["command"] {
        case "front": w.makeKeyAndOrderFront(nil); w.makeFirstResponder(fields[name]); NSApp.activate()
        case "secure": w.makeKeyAndOrderFront(nil); w.makeFirstResponder(passwords[name]); NSApp.activate()
        case "username": w.makeKeyAndOrderFront(nil); w.makeFirstResponder(usernames[name]); NSApp.activate()
        case "resize": w.setContentSize(NSSize(width: 420, height: 300))
        case "ambiguous":
            if let other = windows["B"], let first = windows["A"] { other.setFrame(first.frame, display: true); other.title = first.title }
        case "multiline":
            if let view = multilineScrolls[name] { w.contentView!.addSubview(view); view.isHidden = false }
            w.makeKeyAndOrderFront(nil); w.makeFirstResponder(multiline[name]); NSApp.activate()
        case "plain": multilineScrolls[name]?.isHidden = true; w.makeKeyAndOrderFront(nil); w.makeFirstResponder(fields[name]); NSApp.activate()
        case "move": w.setFrameOrigin(NSPoint(x: w.frame.minX + 40, y: w.frame.minY + 25))
        case "close":
            w.close(); windows.removeValue(forKey: name); fields.removeValue(forKey: name)
            buttons.removeValue(forKey: name); scrolls.removeValue(forKey: name)
            likes.removeValue(forKey: name); deletions.removeValue(forKey: name)
            liked.removeValue(forKey: name); deletionAttempts.removeValue(forKey: name)
            clicks.removeValue(forKey: name); saved.removeValue(forKey: name)
        case "arm": setupComplete = true
        case "state": break
        case "quit": NSApp.terminate(nil)
        default: return
        }
        emitState()
    }
    func fieldValue(_ name: String) -> String { fields[name]!.currentEditor()?.string ?? fields[name]!.stringValue }
    func emitState() {
        let h = NSScreen.screens[0].frame.height
        let entries: [[String: Any]] = windows.keys.sorted().map { name in
            let w = windows[name]!, r = w.frame
            let b = w.convertToScreen(buttons[name]!.convert(buttons[name]!.bounds, to: nil))
            let l = w.convertToScreen(likes[name]!.convert(likes[name]!.bounds, to: nil))
            let d = w.convertToScreen(deletions[name]!.convert(deletions[name]!.bounds, to: nil))
            let scroll = scrolls[name]!
            let s = w.convertToScreen(scroll.convert(scroll.bounds, to: nil))
            return ["name": name, "id": w.windowNumber, "pid": getpid(), "title": w.title,
                    "button": ["x": b.midX - r.minX, "y": r.maxY - b.midY], "saved": saved[name]!,
                    "like": ["x": l.midX - r.minX, "y": r.maxY - l.midY], "liked": liked[name]!,
                    "delete": ["x": d.midX - r.minX, "y": r.maxY - d.midY], "deletionAttempts": deletionAttempts[name]!,
                    "scroll": ["x": s.midX - r.minX, "y": r.maxY - s.midY], "scrollY": scroll.contentView.bounds.minY,
                    "bounds": ["x": r.minX, "y": h - r.maxY, "width": r.width, "height": r.height],
                    "credentialDummyMatches": (passwords[name]?.currentEditor()?.string ?? passwords[name]?.stringValue) == "dummy-credential-QA-only",
                    "usernameDummyMatches": (usernames[name]?.currentEditor()?.string ?? usernames[name]?.stringValue) == "dummy-credential-QA-only",
                    "text": fieldValue(name), "multilineText": multiline[name]?.string ?? "", "clicks": clicks[name]!, "visible": w.isVisible]
        }
        if let bytes = try? JSONSerialization.data(withJSONObject: ["windows": entries, "receivedEvents": receivedEvents,
            "active": NSApp.isActive, "keyWindow": NSApp.keyWindow?.windowNumber ?? -1]) {
            try? bytes.write(to: URL(fileURLWithPath: ready), options: .atomic)
        }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let fixture = Fixture()
app.delegate = fixture
withExtendedLifetime(fixture) { app.run() }
