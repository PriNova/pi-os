import AppKit
import ServiceManagement
import PiOSCore

@MainActor protocol ModelSettingsService: AnyObject {
    func reserve() -> UUID
    func release(_ id: UUID)
    func models() async throws -> HarnessClient.ModelCatalog
    func setModel(_ selection: HarnessClient.ModelSelection) async throws
    func resources() async throws -> HarnessClient.ResourceSettings
    func setResources(trusted: Bool) async throws
}
extension HarnessClient: ModelSettingsService {}

/// Model settings stay Node-owned, exactly as on Windows. No shell or SDK in the UI.
@MainActor final class SettingsWindow: NSWindowController, NSWindowDelegate {
    private let harness: ModelSettingsService
    private let notifier: ResultNotifier
    private var reservation: UUID?
    private var task: Task<Void, Never>?
    private var busy = false
    private var catalog: HarnessClient.ModelCatalog?
    private var visibleModels: [HarnessClient.Model] = []
    private let providers = NSPopUpButton()
    private let models = NSPopUpButton()
    private let efforts = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString: "Loading models…")
    private let access = NSTextField(wrappingLabelWithString: "")
    private let apply = NSButton(title: "Apply", target: nil, action: nil)
    private let control = NSButton(checkboxWithTitle: "Allow computer control in my chosen window", target: nil, action: nil)
    private let notifications = NSButton(checkboxWithTitle: "Notify when a background task finishes", target: nil, action: nil)
    private let compatibility = NSButton(checkboxWithTitle: "Use trusted global pi extensions and coding tools", target: nil, action: nil)
    private let login = NSButton(checkboxWithTitle: "Open pi-os at login", target: nil, action: nil)
    private let credentials = NSButton(checkboxWithTitle: "Allow input in username and password fields", target: nil, action: nil)
    var onClosed: (() -> Void)?
    var onPermissions: (() -> Void)?
    var onControlDisabled: (() -> Void)?

    init(harness: ModelSettingsService, notifier: ResultNotifier) {
        self.harness = harness; self.notifier = notifier
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 652),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "pi-os Settings"; window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let view = FlippedView(frame: window.contentView!.bounds)
        window.contentView = view
        let heading = PanelStyle.label("Your agent", size: 18, weight: .semibold, color: .labelColor)
        heading.frame = NSRect(x: 28, y: 24, width: 300, height: 26); view.addSubview(heading)
        let detail = PanelStyle.label("Model changes apply to your next task.", size: 12)
        detail.frame = NSRect(x: 28, y: 56, width: 480, height: 20); view.addSubview(detail)
        for (index, row) in [("Provider", providers), ("Model", models), ("Reasoning effort", efforts)].enumerated() {
            let y = 94 + CGFloat(index) * 40
            let label = PanelStyle.label(row.0, size: 13, color: .labelColor)
            label.frame = NSRect(x: 28, y: y + 4, width: 130, height: 24); view.addSubview(label)
            row.1.frame = NSRect(x: 170, y: y, width: 360, height: 30)
            row.1.setAccessibilityLabel(row.0); view.addSubview(row.1)
        }
        providers.target = self; providers.action = #selector(providerChanged)
        models.target = self; models.action = #selector(modelChanged)
        status.font = .systemFont(ofSize: 12); status.textColor = PanelStyle.secondaryInk
        status.frame = NSRect(x: 28, y: 216, width: 502, height: 42); view.addSubview(status)
        control.frame = NSRect(x: 28, y: 268, width: 502, height: 24)
        control.state = ControlAvailability.requested ? .on : .off
        control.target = self; control.action = #selector(controlChanged); view.addSubview(control)
        access.font = .systemFont(ofSize: 11); access.textColor = PanelStyle.secondaryInk
        access.stringValue = ControlAvailability.explanation
        access.frame = NSRect(x: 48, y: 296, width: 470, height: 40); view.addSubview(access)
        notifications.frame = NSRect(x: 28, y: 340, width: 502, height: 24)
        notifications.state = UserDefaults.standard.bool(forKey: ResultNotifier.enabledKey) ? .on : .off
        notifications.isEnabled = ControlAvailability.stableSignature
        notifications.target = self; notifications.action = #selector(notificationsChanged); view.addSubview(notifications)
        login.frame = NSRect(x: 28, y: 372, width: 502, height: 24)
        login.isEnabled = ControlAvailability.stableSignature
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.target = self; login.action = #selector(loginChanged); view.addSubview(login)
        compatibility.frame = NSRect(x: 28, y: 408, width: 502, height: 24)
        compatibility.isEnabled = false; compatibility.target = self; compatibility.action = #selector(compatibilityChanged)
        compatibility.toolTip = "Explicit opt-in. These extensions and tools are not confined to the pinned window. Changes apply to the next task."
        view.addSubview(compatibility)
        let caution = PanelStyle.label("Pinned-only is the default. Trusted code can act outside the chosen window.", size: 11)
        caution.frame = NSRect(x: 48, y: 438, width: 480, height: 20); view.addSubview(caution)
        let browser = NSButton(title: "Brave Connection…", target: self, action: #selector(browserSetup))
        browser.bezelStyle = .rounded; browser.frame = NSRect(x: 28, y: 474, width: 170, height: 32); view.addSubview(browser)
        let browserHint = PanelStyle.label("Use your live tab, without a separate profile.", size: 11)
        browserHint.frame = NSRect(x: 210, y: 480, width: 320, height: 20); view.addSubview(browserHint)
        credentials.frame = NSRect(x: 28, y: 516, width: 502, height: 24)
        credentials.state = CredentialFields.allowed ? .on : .off
        credentials.isEnabled = ControlAvailability.ready
        credentials.target = self; credentials.action = #selector(credentialsChanged); view.addSubview(credentials)
        let credentialHint = NSTextField(wrappingLabelWithString: "Off by default. Only clearly identified login fields are blocked; ordinary typing stays available. Field values remain omitted from text snapshots.")
        credentialHint.font = .systemFont(ofSize: 11); credentialHint.textColor = PanelStyle.secondaryInk
        credentialHint.frame = NSRect(x: 48, y: 546, width: 470, height: 40); view.addSubview(credentialHint)
        let permissions = NSButton(title: "Permissions…", target: self, action: #selector(openPermissions))
        permissions.bezelStyle = .rounded; permissions.frame = NSRect(x: 28, y: 604, width: 128, height: 32); view.addSubview(permissions)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"; cancel.frame = NSRect(x: 354, y: 604, width: 82, height: 32); view.addSubview(cancel)
        apply.bezelStyle = .rounded; apply.keyEquivalent = "\r"; apply.frame = NSRect(x: 446, y: 604, width: 84, height: 32)
        apply.target = self; apply.action = #selector(save); apply.isEnabled = false; view.addSubview(apply)
        reservation = harness.reserve()
        load()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present() { window?.center(); showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate() }
    private func load() {
        busy = true; apply.isEnabled = false; compatibility.isEnabled = false
        providers.isEnabled = false; models.isEnabled = false; efforts.isEnabled = false
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.busy = false
                self.providers.isEnabled = true; self.models.isEnabled = true; self.efforts.isEnabled = true
                self.compatibility.isEnabled = ControlAvailability.ready
            }
            do {
                let resources = try await self.harness.resources()
                self.compatibility.state = resources.current.mode == "trustedGlobal" ? .on : .off
                let catalog = try await self.harness.models()
                try Task.checkCancellation()
                self.catalog = catalog
                self.providers.removeAllItems()
                self.providers.addItems(withTitles: Array(Set(catalog.models.map(\.provider))).sorted())
                if let provider = catalog.current?.provider { self.providers.selectItem(withTitle: provider) }
                self.populateModels()
                self.status.stringValue = catalog.models.isEmpty
                    ? "No authenticated models. Run pi /login or configure a provider API key, then reopen Settings."
                    : "\(catalog.models.count) authenticated models. Control, notification and login switches apply immediately."
            } catch is CancellationError { }
            catch { self.status.stringValue = error.localizedDescription }
        }
    }
    private func populateModels() {
        visibleModels = (catalog?.models ?? []).filter { $0.provider == providers.titleOfSelectedItem }.sorted { $0.name < $1.name }
        models.removeAllItems(); models.addItems(withTitles: visibleModels.map { "\($0.name) · \($0.id)" })
        if let index = visibleModels.firstIndex(where: { $0.id == catalog?.current?.modelId }) { models.selectItem(at: index) }
        populateEfforts()
    }
    private func populateEfforts() {
        efforts.removeAllItems()
        guard visibleModels.indices.contains(models.indexOfSelectedItem) else { apply.isEnabled = false; return }
        let model = visibleModels[models.indexOfSelectedItem]
        efforts.addItems(withTitles: model.thinkingLevels)
        if let level = catalog?.current?.thinkingLevel, model.thinkingLevels.contains(level) { efforts.selectItem(withTitle: level) }
        apply.isEnabled = efforts.indexOfSelectedItem >= 0
    }
    @objc private func providerChanged() { populateModels() }
    @objc private func modelChanged() { populateEfforts() }
    @objc private func controlChanged() {
        UserDefaults.standard.set(control.state == .on, forKey: ControlAvailability.preferenceKey)
        access.stringValue = ControlAvailability.explanation
        compatibility.isEnabled = ControlAvailability.ready
        credentials.isEnabled = ControlAvailability.ready
        if control.state == .off { onControlDisabled?() }
    }
    @objc private func compatibilityChanged() {
        let trusted = compatibility.state == .on
        if trusted {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Trust your global pi configuration?"
            alert.informativeText = "This loads your pi extensions, skills, prompts and coding tools. Extensions execute code with pi-os permissions. They can read/write files, run commands or act outside the pinned window. Native desktop guards cannot sandbox arbitrary extension code.\n\nOnly enable code you trust. This applies to the next task, not an already-running task."
            alert.addButton(withTitle: "Enable Trusted Compatibility")
            alert.addButton(withTitle: "Keep Pinned-Only")
            guard alert.runModal() == .alertFirstButtonReturn else { compatibility.state = .off; return }
        }
        busy = true; compatibility.isEnabled = false; apply.isEnabled = false
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.harness.setResources(trusted: trusted)
                self.status.stringValue = trusted ? "Trusted compatibility enabled for the next task. Reloading its model catalog…" : "Pinned-only mode enabled for the next task."
                self.load()
            } catch {
                self.busy = false
                self.compatibility.state = trusted ? .off : .on
                self.populateEfforts()
                self.compatibility.isEnabled = ControlAvailability.ready
                self.status.stringValue = error.localizedDescription
            }
        }
    }
    @objc private func notificationsChanged() {
        if notifications.state == .off { UserDefaults.standard.set(false, forKey: ResultNotifier.enabledKey); return }
        notifications.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            let granted = await self.notifier.requestPermission()
            UserDefaults.standard.set(granted, forKey: ResultNotifier.enabledKey)
            self.notifications.state = granted ? .on : .off; self.notifications.isEnabled = true
            if !granted { self.status.stringValue = "Notifications were not enabled. Background results will use a native in-app toast." }
        }
    }
    @objc private func loginChanged() {
        do {
            if login.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval { status.stringValue = "Approve pi-os in System Settings → General → Login Items." }
        } catch { login.state = SMAppService.mainApp.status == .enabled ? .on : .off; status.stringValue = error.localizedDescription }
    }
    @objc private func credentialsChanged() {
        let allow = credentials.state == .on
        if allow && !CredentialFields.confirmEnable() { credentials.state = .off; return }
        UserDefaults.standard.set(allow, forKey: CredentialPolicy.preferenceKey)
        onControlDisabled?()
        status.stringValue = allow ? "Credential-field input enabled. Stored values are still omitted from text snapshots." : "Username and password fields are blocked. Ordinary typing and clicks remain available."
    }
    @objc private func browserSetup() { BrowserSetup.present { onControlDisabled?() } }
    @objc private func openPermissions() { onPermissions?() }
    @objc private func cancel() { close() }
    @objc private func save() {
        guard visibleModels.indices.contains(models.indexOfSelectedItem), let level = efforts.titleOfSelectedItem else { return }
        let model = visibleModels[models.indexOfSelectedItem]
        let selection = HarnessClient.ModelSelection(provider: model.provider, modelId: model.id, thinkingLevel: level)
        busy = true; compatibility.isEnabled = false
        apply.isEnabled = false; status.stringValue = "Applying…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.compatibility.isEnabled = ControlAvailability.ready }
            do { try await self.harness.setModel(selection); self.close() }
            catch { self.status.stringValue = error.localizedDescription; self.apply.isEnabled = true }
        }
    }
    func windowDidBecomeKey(_ notification: Notification) {
        access.stringValue = ControlAvailability.explanation
        control.state = ControlAvailability.requested ? .on : .off
        credentials.state = CredentialFields.allowed ? .on : .off
        credentials.isEnabled = ControlAvailability.ready
        compatibility.isEnabled = !busy && ControlAvailability.ready && catalog != nil
    }
    func windowWillClose(_ notification: Notification) {
        task?.cancel(); task = nil
        if let reservation { harness.release(reservation); self.reservation = nil }
        onClosed?()
    }
}
