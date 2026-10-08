import AppKit
import CoreGraphics
import ApplicationServices
import PiOSCore

@MainActor public final class Application: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var config: MacConfiguration!
    private var lock: InstanceLock?
    private var server: LoopbackServer?
    private var desktop: DesktopService!
    private var harness: HarnessClient!
    private var hotkey: GlobalHotkey?
    private var status: NSStatusItem!
    private var diagnostic: NSMenuItem!
    private var availability: NSMenuItem!
    private var lastAnswerItem: NSMenuItem!
    private var cancelItem: NSMenuItem!
    private let panel = PromptPanel()
    private let notifier = ResultNotifier()
    private var settingsWindow: SettingsWindow?
    private var appearanceWindow: AppearanceWindow?
    private var invocationReservation: UUID?
    private var workDismissed = false
    private var nativeInputStarted = false
    private var latestResultID: String?
    private var context: String?
    private var invocation: String?
    private var thread: String?
    private var submitted = false
    private var cancelRequested = false
    private var preparation: Task<Void, Error>?
    private var running: Task<Void, Never>?
    private var failure: String?
    private var shutdownPending = false

    public func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        do {
            config = try MacConfiguration()
            lock = try InstanceLock(directory: config.support)
            let configuration = config!
            desktop = DesktopService(captures: config.captures, token: config.token,
                controlEnabled: { configuration.canControl }, traceFile: config.support.appendingPathComponent("logs/host-actions.jsonl"),
                beforeInput: { [weak self] in
                    await MainActor.run {
                        guard let self else { return false }
                        self.nativeInputStarted = true
                        return self.panel.suspendForInput()
                    }
                })
            // Keep the floating UI out of the way once input starts; do not restore it
            // between asynchronous WindowServer events. The result/notification ends this phase.
            notifier.onOpen = { [weak self] id in
                guard let self, id == self.latestResultID, self.invocation == nil else { return }
                self.panel.reopenLatestResult()
            }
            harness = HarnessClient(config: config)
            harness.onUnexpectedExit = { [weak self] in
                guard let self, self.context != nil else { return }
                self.discardContext()
                self.releaseInvocationReservation()
                self.showError(DomainError("harness_unreachable", "The agent process exited. Check logs/harness.log, then try again."))
            }
            createMenu()
            panel.onSubmit = { [weak self] in self?.submit($0) }
            panel.onFollowup = { [weak self] in self?.submit($0, followup: true) }
            panel.onCancel = { [weak self] in self?.cancel() }
            panel.onPermissions = { [weak self] in self?.permissions() }
            panel.onDismissWork = { [weak self] in
                self?.workDismissed = true; self?.panel.dismissWorking()
            }
            let service = desktop!
            server = try LoopbackServer(port: config.hostPort) { await service.handle($0) }
            server?.onFailure = { [weak self] message in
                Task { @MainActor in self?.fatal(message) }
            }
            server?.start { [weak self] in
                Task { @MainActor in self?.ready() }
            }
        } catch let error as DomainError where error.code == "already_running" {
            // flock, not a failed port bind, establishes that another instance owns this directory.
            NSApp.terminate(nil)
        } catch { fatal(error.localizedDescription) }
    }
    private func ready() {
        guard failure == nil else { return }
        do {
            let raw = ProcessInfo.processInfo.environment["PI_OS_HOTKEY"] ?? HotkeyChord.defaultValue
            hotkey = try GlobalHotkey(chord: HotkeyChord(raw)) { [weak self] in self?.invoke() }
            diagnostic.title = hotkey?.systemConflict == true
                ? "Hotkey conflicts with a macOS shortcut — change PI_OS_HOTKEY"
                : "Ready · \(raw)"
            // Pay the first public CG enumeration cost at launch, never enumerate SCK here.
            _ = DesktopIdentity.windows()
            panel.prewarm()
            setStatus("Ready when you are")
        } catch { diagnostic.title = error.localizedDescription; showError(error) }
    }
    private func createMenu() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = PanelStyle.menuIcon()
        status.button?.setAccessibilityLabel("pi-os")
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
        let title = NSMenuItem(title: "pi-os", action: nil, keyEquivalent: "")
        title.attributedTitle = NSAttributedString(string: "pi-os", attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold)])
        title.isEnabled = false; menu.addItem(title)
        availability = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        availability.isEnabled = false; menu.addItem(availability); menu.addItem(.separator())
        let ask = menuItem("Ask About This Window…", #selector(invokeFromMenu), symbol: "sparkle")
        if ProcessInfo.processInfo.environment["PI_OS_HOTKEY"] == nil {
            ask.keyEquivalent = " "; ask.keyEquivalentModifierMask = [.control, .option, .command]
        }
        menu.addItem(ask)
        lastAnswerItem = menuItem("Show Last Answer", #selector(showCurrent), symbol: "text.bubble")
        menu.addItem(lastAnswerItem)
        cancelItem = menuItem("Cancel Task", #selector(cancelFromMenu), symbol: "stop.circle")
        menu.addItem(cancelItem); menu.addItem(.separator())
        let settings = menuItem("Settings…", #selector(showSettings), symbol: "slider.horizontal.3")
        settings.keyEquivalent = ","; menu.addItem(settings)
        menu.addItem(menuItem("Appearance…", #selector(showAppearance), symbol: "paintpalette"))
        menu.addItem(menuItem("Brave Connection…", #selector(browserSetup), symbol: "globe"))
        menu.addItem(menuItem("Permissions…", #selector(permissions), symbol: "lock.shield"))
        let diagnostics = NSMenuItem(title: "Diagnostics", action: nil, keyEquivalent: "")
        let submenu = NSMenu(); submenu.autoenablesItems = false
        diagnostic = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: ""); diagnostic.isEnabled = false
        submenu.addItem(diagnostic); submenu.addItem(.separator())
        submenu.addItem(menuItem("Open Logs…", #selector(openLogs), symbol: "folder"))
        diagnostics.submenu = submenu; menu.addItem(diagnostics)
        menu.addItem(menuItem("About pi-os", #selector(about)))
        menu.addItem(.separator())
        let quit = menuItem("Quit pi-os", #selector(quit)); quit.keyEquivalent = "q"
        menu.addItem(quit)
        status.menu = menu
    }
    @objc private func showAppearance() {
        if appearanceWindow == nil { appearanceWindow = AppearanceWindow() }
        appearanceWindow?.present()
    }
    private func menuItem(_ title: String, _ action: Selector, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; item.image = symbol.flatMap { PanelStyle.symbol($0) }
        return item
    }
    public func menuWillOpen(_ menu: NSMenu) {
        lastAnswerItem.title = invocation != nil ? "Show Current Task" : panel.mode == .prompt ? "Show Question" : "Show Last Answer"
        lastAnswerItem.isEnabled = (invocation != nil && !nativeInputStarted) || panel.mode == .prompt || (invocation == nil && panel.hasLastAnswer)
        cancelItem.isHidden = invocation == nil
        cancelItem.isEnabled = !cancelRequested
    }
    private func setStatus(_ text: String, attention: Bool = false) {
        status?.button?.image = PanelStyle.menuIcon(attention: attention)
        status?.button?.toolTip = "pi-os — " + text
        status?.button?.setAccessibilityLabel("pi-os — " + text)
        availability?.title = text
    }
    private func invoke() {
        guard failure == nil else { showError(DomainError("startup_failed", failure!)); return }
        if invocation != nil { if !nativeInputStarted { workDismissed = false; panel.reveal() }; return }
        if panel.mode == .prompt { cancel(); return }
        panel.hide()
        discardContext()
        let start = DispatchTime.now().uptimeNanoseconds
        let perf = ProcessInfo.processInfo.environment["PI_OS_PERF"] == "1"
        if perf { panel.measureNextVisibility(from: start) }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var snapshot = DesktopIdentity.pin()
        DesktopAX.enrichBeforePanel(&snapshot)
        let browserPin = BrowserPin.capture(&snapshot)
        context = snapshot.id
        workDismissed = false; nativeInputStarted = false; latestResultID = nil
        panel.prompt(snapshot: snapshot, appName: NSWorkspace.shared.frontmostApplication?.localizedName ?? "Desktop", canControl: config.canControl, trustedCompatibility: config.trustedCompatibility)
        if perf {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            // CPU-side proxy only; not a claim about first compositor frame.
            print("[perf] pin-to-panel-order ms=\(ms) frontmost-preserved=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontPID)")
            fflush(stdout)
        }
        guard !config.echo else { return }
        let id = snapshot.id, desktop = desktop!, harness = harness!
        invocationReservation = harness.reserve()
        preparation = Task {
            try Task.checkCancellation()
            await desktop.insert(snapshot, browserPin: browserPin)
            try Task.checkCancellation()
            async let warm: Void = harness.warm()
            async let shot = desktop.capture(id)
            _ = try await (warm, shot)
            try Task.checkCancellation()
        }
    }
    private func submit(_ prompt: String, followup: Bool = false) {
        guard let id = context, invocation == nil, !followup || thread != nil else { return }
        if config.echo { panel.reader(prompt); return }
        let invocationID = followup ? thread! : "inv-" + UUID().uuidString
        workDismissed = false; nativeInputStarted = false; cancelRequested = false
        invocation = invocationID
        setStatus("Working on your question")
        panel.pill(followup ? "Continuing your conversation…" : "Preparing the pinned window…")
        running = Task { [weak self] in
            guard let self else { return }
            do {
                if !followup { try await self.preparation?.value }
                try Task.checkCancellation()
                if followup { try await self.harness.followup(invocationID, prompt: prompt) }
                else { try await self.harness.submit(id: invocationID, context: id, prompt: prompt) }
                try Task.checkCancellation()
                self.submitted = true
                self.thread = invocationID
                while true {
                    try Task.checkCancellation()
                    let state = try await self.harness.status(invocationID)
                    guard self.invocation == invocationID else { return }
                    switch state.state {
                    case "queued", "running":
                        if !self.cancelRequested { self.panel.updateActivity(state.activity == "thinking" ? "Thinking…" : Self.activityLabel(state.activity)) }
                    case "completed":
                        self.thread = state.followupAvailable == true ? invocationID : nil
                        self.panel.setFollowupEnabled(self.thread != nil)
                        self.panel.reader(state.responseText?.isEmpty == false ? state.responseText! : "The agent returned no answer.", present: !self.workDismissed)
                        await self.backgroundResult(invocationID, failed: false)
                        guard self.invocation == invocationID else { return }
                        self.finish(); return
                    case "aborted":
                        self.panel.hide(); self.finish(cancelled: true); return
                    default:
                        self.thread = state.followupAvailable == true ? invocationID : nil
                        throw DomainError(state.state, state.failureMessage ?? "The task did not complete")
                    }
                    // No status polling exists outside this active invocation task.
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
            } catch is CancellationError { /* explicit cancel owns UI and child teardown */ }
            catch {
                guard self.invocation == invocationID else { return }
                if (error as? DomainError)?.code == "harness_unreachable" { self.harness.stop() }
                let code = (error as? DomainError)?.code
                // A lost POST response is not permission to replay the prompt. End that
                // thread; only an explicit terminal/rejection status can permit retry.
                if !self.submitted && code != "not_idle" { self.discardContext() }
                self.panel.setFollowupEnabled(self.thread != nil)
                if followup && !self.workDismissed {
                    self.panel.restoreAfterFollowupFailure(error, retry: self.thread != nil)
                } else { self.panel.showFailure(error, present: !self.workDismissed) }
                await self.backgroundResult(invocationID, failed: true)
                guard self.invocation == invocationID else { return }
                self.finish(failed: true)
            }
        }
    }
    private static func activityLabel(_ name: String?) -> String {
        switch name {
        case "desktop_capture_window": return "Looking at the window…"
        case "desktop_get_context", "desktop_refresh_context": return "Reading context…"
        case "desktop_act": return "Working in your window…"
        case "browser_snapshot": return "Reading your Brave tab…"
        case "browser_act": return "Working in your Brave tab…"
        default: return "Working on your request…"
        }
    }
    private func backgroundResult(_ id: String, failed: Bool) async {
        latestResultID = id
        if workDismissed {
            let notified = await notifier.notify(invocation: id, failed: failed)
            if !notified && invocation == id && latestResultID == id { panel.completionToast(failed: failed) }
        }
    }
    private func releaseInvocationReservation() {
        if let invocationReservation { harness.release(invocationReservation); self.invocationReservation = nil }
    }
    private func finish(cancelled: Bool = false, failed: Bool = false) {
        invocation = nil; submitted = false; cancelRequested = false; running = nil; preparation = nil
        setStatus(cancelled ? "Task cancelled" : failed ? "Your request needs attention" : "Your answer is ready", attention: !cancelled)
        if cancelled || thread == nil {
            discardContext(); releaseInvocationReservation()
        }
        // A visible/background reader reserves the child until its thread closes.
        harness.retainWarm()
    }
    private func showError(_ error: Error) {
        panel.showFailure(error)
        setStatus("Your request needs attention", attention: true)
    }
    private func cancel() {
        if let id = invocation, submitted {
            guard !cancelRequested else { return }
            cancelRequested = true
            panel.updateActivity("Cancelling…")
            Task { [weak self] in
                guard let self else { return }
                if let context = self.context { await self.desktop.remove(context) }
                let accepted = await self.harness.cancel(id)
                guard self.invocation == id else { return }
                if !accepted { self.hardCancel(); return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if self.invocation == id { self.hardCancel() }
            }
            return
        }
        hardCancel()
    }
    private func hardCancel() {
        let wasPrompt = panel.mode == .prompt
        let active = invocation
        invocation = nil; submitted = false; cancelRequested = false; running?.cancel(); running = nil
        preparation?.cancel(); preparation = nil
        panel.hide(); setStatus("Ready when you are")
        discardContext()
        releaseInvocationReservation()
        if active != nil || wasPrompt {
            // Teardown is a hard cancellation backstop; never leave an orphan request running.
            // Close only the owned group, never node processes by executable name.
            if active != nil { harness.stop() }
            else { harness.stopIfUnused() }
        }
    }
    private func discardContext() {
        let oldContext = context, oldThread = thread, reservation = invocationReservation
        context = nil; thread = nil; invocationReservation = nil
        panel.setFollowupEnabled(false)
        if let desktop, let harness {
            Task {
                // Native lease removal precedes asynchronous harness closure.
                if let oldContext { await desktop.remove(oldContext) }
                if let oldThread { await harness.closeThread(oldThread) }
                if let reservation { harness.release(reservation) }
            }
        }
    }
    private func fatal(_ message: String) {
        failure = message
        let alert = NSAlert()
        alert.messageText = "pi-os couldn’t start"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }
    @objc private func invokeFromMenu() { invoke() }
    @objc private func showCurrent() {
        if invocation != nil { if !nativeInputStarted { workDismissed = false; panel.reveal() } }
        else if panel.mode == .prompt { panel.reveal() }
        else { panel.reopenLastAnswer() }
    }
    @objc private func showSettings() {
        if let settingsWindow { settingsWindow.present(); return }
        let controller = SettingsWindow(harness: harness, notifier: notifier)
        controller.onClosed = { [weak self] in self?.settingsWindow = nil }
        controller.onPermissions = { [weak self] in self?.permissions() }
        controller.onControlDisabled = { [weak self] in
            guard let self else { return }
            if self.invocation != nil || self.panel.mode == .prompt || self.thread != nil { self.cancel() }
        }
        settingsWindow = controller; controller.present()
    }
    @objc private func browserSetup() {
        BrowserSetup.present { if invocation != nil || panel.mode == .prompt || thread != nil { cancel() } }
    }
    @objc private func cancelFromMenu() { cancel() }
    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "pi-os",
            .applicationVersion: "0.1 · Native macOS preview",
            .credits: NSAttributedString(string: "Your chosen window. Your existing pi agent.\nA quiet, read-only assistant, one shortcut away."),
        ])
    }
    @objc private func openLogs() { NSWorkspace.shared.open(config.support.appendingPathComponent("logs")) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func permissions() {
        let allowed = CGPreflightScreenCaptureAccess()
        let alert = NSAlert()
        alert.messageText = "pi-os Permissions"
        alert.informativeText = "Screen Recording: \(allowed ? "allowed" : "not allowed")\n\n\(ControlAvailability.explanation)\n\nScreen Recording reads your chosen window. Accessibility allows verified clicks, typing and shortcuts in that same window. Input Monitoring is not required. Quit/reopen if macOS requests it."
        alert.addButton(withTitle: allowed ? "Screen Recording Settings…" : "Allow Screen Recording")
        alert.addButton(withTitle: ControlAvailability.ready ? "Accessibility Settings…" : "Enable Computer Control…")
        alert.buttons[1].isEnabled = ControlAvailability.stableSignature
        alert.addButton(withTitle: "Done")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if !allowed { _ = CGRequestScreenCaptureAccess() }
            else { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }
        }
        if response == .alertSecondButtonReturn && ControlAvailability.stableSignature {
            UserDefaults.standard.set(true, forKey: ControlAvailability.preferenceKey)
            if !AXIsProcessTrusted() { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
            if AXIsProcessTrusted() && !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !shutdownPending, let desktop else { return .terminateNow }
        shutdownPending = true
        running?.cancel(); preparation?.cancel(); harness?.stop(); server?.stop()
        Task {
            await desktop.removeAll()
            // Give the exact owned process group its termination grace period before host exit.
            try? await Task.sleep(nanoseconds: 2_100_000_000)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
