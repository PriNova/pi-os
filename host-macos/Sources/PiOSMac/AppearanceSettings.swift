import AppKit
import PiOSCore

@MainActor final class AppearanceSettings {
    static let shared: AppearanceSettings = {
        let env = ProcessInfo.processInfo.environment
        if env["PI_OS_INSTALLED_TEST"] == "1", let support = env["PI_OS_SUPPORT_DIR"], !support.isEmpty,
           let defaults = UserDefaults(suiteName: "dev.pi-os.appearance-fixture." + URL(fileURLWithPath: support).lastPathComponent) {
            return AppearanceSettings(defaults: defaults)
        }
        return AppearanceSettings()
    }()
    static let changed = Notification.Name("PiOSAppearanceChanged")
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var value: AppearancePreferences {
        AppearancePreferences(preset: AppearancePreset(rawValue: defaults.string(forKey: "appearancePreset") ?? "") ?? .system,
            largerText: defaults.bool(forKey: "appearanceLargerText"),
            reduceTransparency: defaults.bool(forKey: "appearanceReduceTransparency"),
            lowerInset: defaults.object(forKey: "appearanceLowerInset") as? Double ?? 32)
    }
    func set(_ value: AppearancePreferences) {
        let normalized = AppearancePreferences(preset: value.preset, largerText: value.largerText,
            reduceTransparency: value.reduceTransparency, lowerInset: value.lowerInset)
        defaults.set(normalized.preset.rawValue, forKey: "appearancePreset")
        defaults.set(normalized.largerText, forKey: "appearanceLargerText")
        defaults.set(normalized.reduceTransparency, forKey: "appearanceReduceTransparency")
        defaults.set(normalized.lowerInset, forKey: "appearanceLowerInset")
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
    var appearance: NSAppearance? {
        switch value.preset {
        case .system: return nil
        case .graphite: return NSAppearance(named: .darkAqua)
        default: return NSAppearance(named: .aqua)
        }
    }
}

/// Native appearance controls. No harness reservation, catalog discovery or permissions here.
@MainActor final class AppearanceViewController: NSViewController {
    private let settings: AppearanceSettings
    private let presets = NSPopUpButton()
    private let larger = NSButton(checkboxWithTitle: "Larger text", target: nil, action: nil)
    private let solid = NSButton(checkboxWithTitle: "Reduce transparency", target: nil, action: nil)
    private let edge = NSPopUpButton()
    init(settings: AppearanceSettings? = nil) { self.settings = settings ?? .shared; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 292))
        view = root
        let title = PanelStyle.label("Make it yours", size: 15, weight: .semibold, color: .labelColor)
        title.frame = NSRect(x: 22, y: 21, width: 256, height: 22); root.addSubview(title)
        let label = PanelStyle.label("Appearance", size: 12)
        label.frame = NSRect(x: 22, y: 60, width: 104, height: 24); root.addSubview(label)
        presets.addItems(withTitles: AppearancePreset.allCases.map(\.title))
        presets.frame = NSRect(x: 126, y: 56, width: 152, height: 30)
        presets.setAccessibilityLabel("Appearance preset"); presets.target = self; presets.action = #selector(change)
        root.addSubview(presets)
        for (index, button) in [larger, solid].enumerated() {
            button.frame = NSRect(x: 20, y: 104 + CGFloat(index) * 34, width: 260, height: 24)
            button.target = self; button.action = #selector(change); root.addSubview(button)
        }
        let edgeLabel = PanelStyle.label("Lower-edge spacing", size: 12)
        edgeLabel.frame = NSRect(x: 22, y: 184, width: 166, height: 24); root.addSubview(edgeLabel)
        edge.addItems(withTitles: ["20 pt", "32 pt", "48 pt"])
        edge.frame = NSRect(x: 191, y: 180, width: 87, height: 30)
        edge.setAccessibilityLabel("Lower-edge spacing"); edge.target = self; edge.action = #selector(change); root.addSubview(edge)
        let note = NSTextField(wrappingLabelWithString: "System accessibility settings take priority. Appearance never changes your target or permissions.")
        note.font = .systemFont(ofSize: 11); note.textColor = PanelStyle.secondaryInk
        note.frame = NSRect(x: 22, y: 228, width: 256, height: 46); root.addSubview(note)
        synchronize()
        NotificationCenter.default.addObserver(self, selector: #selector(synchronize), name: AppearanceSettings.changed, object: settings)
    }
    @objc private func synchronize() {
        let value = settings.value
        presets.selectItem(at: AppearancePreset.allCases.firstIndex(of: value.preset) ?? 0)
        larger.state = value.largerText ? .on : .off
        solid.state = value.reduceTransparency || value.preset == .contrast ? .on : .off
        solid.isEnabled = value.preset != .contrast
        edge.selectItem(at: [20.0, 32.0, 48.0].firstIndex(of: value.lowerInset) ?? 1)
        view.appearance = settings.appearance
    }
    @objc private func change() {
        var value = settings.value
        value.preset = AppearancePreset.allCases[presets.indexOfSelectedItem]
        value.largerText = larger.state == .on
        // Contrast forces opacity but should not silently persist an unrelated override.
        if value.preset != .contrast && solid.isEnabled { value.reduceTransparency = solid.state == .on }
        value.lowerInset = [20.0, 32.0, 48.0][edge.indexOfSelectedItem]
        settings.set(value)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
}

@MainActor final class AppearanceWindow: NSWindowController {
    init() {
        let controller = AppearanceViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 292),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "pi-os Appearance"; window.isReleasedWhenClosed = false
        window.contentViewController = controller
        super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present() { window?.center(); showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate() }
}
