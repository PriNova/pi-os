import AppKit
import QuartzCore
import PiOSCore

/// One quiet native material, one accent, no window-wide gradients or animated chrome.
@MainActor enum PanelStyle {
    static let corner: CGFloat = 22
    static let inset: CGFloat = 24
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    static var increaseContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    static var preferences: AppearancePreferences { AppearanceSettings.shared.value }
    static var opaque: Bool { preferences.opaque(systemReduceTransparency: reduceTransparency, systemIncreaseContrast: increaseContrast) }
    static var textScale: CGFloat { preferences.largerText ? 1.2 : 1 }
    static var accent: NSColor { preferences.preset == .warm ? NSColor(calibratedRed: 0.57, green: 0.37, blue: 0.22, alpha: 1) : .controlAccentColor }
    // Explicit neutral ink avoids vibrancy washing out small labels and custom-drawn controls.
    static let secondaryInk = NSColor(name: "PiOSSecondaryInk") { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(calibratedWhite: dark ? 0.68 : 0.36, alpha: 1)
    }
    static func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular,
                      color: NSColor? = nil) -> NSTextField {
        let view = NSTextField(labelWithString: text)
        view.font = .systemFont(ofSize: size, weight: weight)
        view.textColor = color ?? secondaryInk
        view.lineBreakMode = .byTruncatingTail
        return view
    }
    static func symbol(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .medium) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }
    static func menuIcon(attention: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            ("π" as NSString).draw(at: NSPoint(x: 2, y: -1), withAttributes: [
                .font: NSFont.systemFont(ofSize: 19, weight: .medium), .foregroundColor: NSColor.black,
            ])
            if attention { NSBezierPath(ovalIn: NSRect(x: 16, y: 12, width: 3, height: 3)).fill() }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Real Apple glass on macOS 26+, with a native visual-effect fallback on 14/15.
/// Content is always inside NSGlassEffectView.contentView, never an arbitrary overlay.
final class PanelSurface: NSView {
    enum Role { case command, reading }
    let embedded = FlippedView()
    private let visual = NSVisualEffectView()
    private var glass: NSView?
    private let wash = NSView()
    let role: Role
    var radius: CGFloat = PanelStyle.corner { didSet { updateColors() } }
    var usesGlass: Bool { glass?.isHidden == false }
    init(role: Role = .command) {
        self.role = role
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerCurve = .continuous
        visual.material = .popover; visual.blendingMode = .behindWindow; visual.state = .active
        visual.wantsLayer = true; visual.layer?.cornerCurve = .continuous; visual.layer?.masksToBounds = true
        addSubview(visual)
        // Older Xcode SDKs do not declare NSGlassEffectView. Keep their native
        // material build path usable as well as guarding the runtime OS version.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let view = NSGlassEffectView(); view.style = .regular
            // Interactive distortion defaults off; avoid a needless SDK-27 property.
            glass = view; addSubview(view)
        }
        #endif
        wash.wantsLayer = true
        visual.addSubview(wash)
        updateColors()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateColors),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout(); visual.frame = bounds; glass?.frame = bounds; wash.frame = visual.bounds
        embedded.frame = bounds
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
    @objc func updateColors() {
        let owner = window
        let responder = owner?.firstResponder as? NSView
        let selection = (responder as? NSTextView)?.selectedRange()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let prefs = PanelStyle.preferences
        let opaque = PanelStyle.opaque
        let useGlass = role == .command && !opaque && prefs.preset != .frost && glass != nil
        visual.isHidden = opaque || useGlass; glass?.isHidden = !useGlass
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let effect = glass as? NSGlassEffectView {
            effect.cornerRadius = radius
            effect.style = .regular
            effect.tintColor = prefs.preset == .warm ? NSColor(calibratedRed: 0.98, green: 0.94, blue: 0.87, alpha: 0.25) : nil
            if useGlass {
                if effect.contentView !== embedded { embedded.removeFromSuperview(); effect.contentView = embedded }
            } else if effect.contentView != nil { effect.contentView = nil }
        }
        #endif
        if !useGlass {
            let parent: NSView = opaque ? self : visual
            if embedded.superview !== parent { embedded.removeFromSuperview(); parent.addSubview(embedded) }
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let background = prefs.preset == .warm ? NSColor(calibratedRed: 0.99, green: 0.97, blue: 0.93, alpha: 1) : NSColor.windowBackgroundColor
            layer?.backgroundColor = opaque ? background.cgColor : NSColor.clear.cgColor
            layer?.cornerRadius = radius
            layer?.borderWidth = opaque ? 1 : 0
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.45).cgColor
            visual.layer?.cornerRadius = radius
            wash.layer?.backgroundColor = background.withAlphaComponent(role == .reading ? (dark ? 0.86 : 0.78) : 0.18).cgColor
            // Native glass supplies its own edge; the fallback only needs a quiet rim.
            visual.layer?.borderWidth = 0.5
            visual.layer?.borderColor = (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.14).cgColor
        }
        needsLayout = true
        if let responder, responder.isDescendant(of: embedded) {
            owner?.makeFirstResponder(responder)
            if let selection { (responder as? NSTextView)?.setSelectedRange(selection) }
        }
    }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// Native button semantics, focus ring, hover and press feedback. No custom event-tracking loop.
final class PanelButton: NSButton {
    enum Kind { case quiet, filled, primary }
    var kind: Kind = .quiet
    var rounded = false
    var symbolSize: CGFloat = 14
    private var hovered = false
    private var tracking: NSTrackingArea?
    override var isHighlighted: Bool { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    init(_ title: String, symbol: String? = nil, kind: Kind = .quiet, action: @escaping () -> Void) {
        self.kind = kind; self.actionBlock = action
        super.init(frame: .zero)
        self.title = title
        image = symbol.flatMap { PanelStyle.symbol($0) }
        imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .exterior
        font = .systemFont(ofSize: 12, weight: .medium)
        target = self; self.action = #selector(invokeAction)
        setAccessibilityLabel(title)
    }
    private let actionBlock: () -> Void
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invokeAction() { actionBlock() }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if isHighlighted && isEnabled && !PanelStyle.reduceMotion {
            let t = AffineTransform(translationByX: bounds.midX * 0.04, byY: bounds.midY * 0.04)
            (t as NSAffineTransform).concat()
            NSAffineTransform(transform: AffineTransform(scale: 0.96)).concat()
        }
        let background: NSColor
        let foreground: NSColor
        if kind == .primary {
            background = isEnabled ? PanelStyle.accent : .quaternaryLabelColor
            foreground = isEnabled ? .white : .tertiaryLabelColor
        } else {
            background = NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.12 : hovered ? 0.08 : kind == .filled ? 0.05 : 0)
            foreground = isEnabled ? PanelStyle.secondaryInk : .tertiaryLabelColor
        }
        background.setFill()
        let radius = rounded ? bounds.height / 2 : 8.0
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: font!, .foregroundColor: foreground]
        let textSize = (title as NSString).size(withAttributes: attributes)
        let iconWidth: CGFloat = image == nil ? 0 : symbolSize
        let gap: CGFloat = image == nil || title.isEmpty ? 0 : 6
        let contentWidth = iconWidth + gap + textSize.width
        var x = (bounds.width - contentWidth) / 2
        if let image {
            let tinted = NSImage(size: image.size, flipped: false) { rect in
                image.draw(in: rect)
                foreground.setFill(); rect.fill(using: .sourceAtop)
                return true
            }
            let scale = min(symbolSize / max(1, image.size.width), symbolSize / max(1, image.size.height))
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            tinted.draw(in: NSRect(x: x + (symbolSize - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
            x += iconWidth + gap
        }
        (title as NSString).draw(at: NSPoint(x: x, y: (bounds.height - textSize.height) / 2), withAttributes: attributes)
    }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: rounded ? bounds.height / 2 : 8, yRadius: rounded ? bounds.height / 2 : 8).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }
}

