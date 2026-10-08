import AppKit
import PiOSCore
import PiOSMac

// Isolated visual fixture: no host API, no screen capture, no hotkey, no agent process.
// It is deliberately NOT copied into the installed .app.
let answer = """
## A quieter way to work

The notes describe a **native assistant that stays out of your way**. Three things matter most:

- **Instant access.** One shortcut, in the window you’re already using.
- **A clear boundary.** Only the chosen window is captured. Nothing is clicked or changed.
- **An answer, not another workspace.** Read it, copy what you need, and carry on.

### The next step
Ship the smallest useful experience, then polish the details. Keep `contextId` pinned throughout the task.

> The best interface is the one you barely notice.
"""

@MainActor final class PreviewDelegate: NSObject, NSApplicationDelegate {
    let panel = PromptPanel()
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let mode = args.dropFirst().first ?? "prompt"
        if args.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        if args.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if mode == "settings" { ModelSettingsPreview.show(); return }
        // Process-local appearance overrides never change the installed app's preferences.
        if let index = args.firstIndex(of: "--preset"), args.indices.contains(index + 1) {
            UserDefaults.standard.setVolatileDomain(["appearancePreset": args[index + 1]], forName: UserDefaults.argumentDomain)
        }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.frame
        let h = NSScreen.screens[0].frame.height
        let screenRect = Rect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
        let area = screen.visibleFrame
        let work = Placement.appKit(Rect(x: area.minX, y: area.minY, width: area.width, height: area.height), primaryHeight: h)
        let target = WindowContext(windowID: 1, pid: -1, name: "TextEdit", title: "Product notes.md",
            bounds: Rect(x: frame.midX - 450, y: h - frame.midY - 300, width: 900, height: 600), monitorId: "preview")
        let snapshot = Snapshot(cursor: Point(x: frame.midX, y: frame.midY), target: target, underCursor: nil,
            monitors: [Monitor(id: "preview", name: "Preview", primary: true,
                bounds: Placement.appKit(screenRect, primaryHeight: h), workArea: work)])
        panel.onCancel = { [weak self] in self?.panel.hide(); NSApp.terminate(nil) }
        panel.onPermissions = { [weak self] in
            print("[preview] permission button pressed"); fflush(stdout)
            self?.panel.reader("Permission action verified. This preview never requests a system grant.")
        }
        panel.onSubmit = { [weak self] _ in
            self?.panel.pill("Thinking…")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                self?.panel.setFollowupEnabled(true)
                self?.panel.reader(answer)
            }
        }
        panel.onFollowup = { [weak self] _ in
            self?.panel.pill("Continuing your conversation…")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                self?.panel.setFollowupEnabled(true); self?.panel.reader(answer)
            }
        }
        panel.prewarm()
        panel.measureNextVisibility(from: DispatchTime.now().uptimeNanoseconds)
        panel.prompt(snapshot: snapshot, appName: "TextEdit")
        switch mode {
        case "draft": panel.setDraft("What are the main ideas here?")
        case "multiline": panel.setDraft("Summarize the main ideas in this document.\nKeep it short, and tell me what to do next.")
        case "working": panel.pill("Thinking…")
        case "answer": panel.setFollowupEnabled(true); panel.reader(answer)
        case "short": panel.setFollowupEnabled(true); panel.reader("The meeting is on **Thursday at 10:00**. Bring the revised proposal.")
        case "long": panel.setFollowupEnabled(true); panel.reader(Array(repeating: answer, count: 8).joined(separator: "\n\n"))
        case "appearance": break
        case "error": panel.showFailure(DomainError("permission_denied", "Screen Recording is not allowed"))
        case "failed": panel.showFailure(DomainError("harness_unreachable", "Connection refused"))
        default: break
        }
        // Preview automation may focus this disposable app. Production never activates on hotkey.
        NSApp.activate()
        if mode == "appearance" {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                self.panel.showAppearance()
            }
        }
    }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = PreviewDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
