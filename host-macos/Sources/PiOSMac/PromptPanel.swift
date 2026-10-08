import AppKit
import PiOSCore

private final class NonactivatingPanel: NSPanel {
    var acceptsKeys = true
    var onEscape: (() -> Void)?
    var onCopyAnswer: (() -> Void)?
    override var canBecomeKey: Bool { acceptsKeys }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "c", let onCopyAnswer {
            onCopyAnswer(); return true
        }
        if flags == .command, event.charactersIgnoringModifiers == "w" { onEscape?(); return true }
        if flags == .command, let key = event.charactersIgnoringModifiers,
           let selector = ["a": "selectAll:", "c": "copy:", "v": "paste:", "x": "cut:", "z": "undo:"][key] {
            return NSApp.sendAction(NSSelectorFromString(selector), to: nil, from: self)
        }
        return super.performKeyEquivalent(with: event)
    }
}
private final class PlaceholderLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
enum ComposerKeyPolicy {
    static func submits(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, composing: Bool) -> Bool {
        [UInt16(36), 76].contains(keyCode) && !composing && !modifiers.contains(.shift)
    }
}
private final class PromptEditor: NSTextView {
    var submit: (() -> Void)?
    var dismiss: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if ComposerKeyPolicy.submits(keyCode: event.keyCode, modifiers: event.modifierFlags, composing: hasMarkedText()) {
            submit?(); return
        }
        super.keyDown(with: event)
    }
    override func cancelOperation(_ sender: Any?) { dismiss?() }
}

/// Whisper: one pre-created nonactivating native window, two independent materials.
/// The bar stays at the display's lower edge; the detached reader grows upward.
/// Presentation never changes context authority, follow-up ownership or permissions.
@MainActor public final class PromptPanel: NSObject, NSTextViewDelegate, NSWindowDelegate {
    public enum Mode: Equatable { case hidden, prompt, pill, reader, toast }
    public private(set) var mode: Mode = .hidden
    public var onSubmit: ((String) -> Void)?
    public var onFollowup: ((String) -> Void)?
    public private(set) var followupEnabled = false
    public var onCancel: (() -> Void)?
    public var onPermissions: (() -> Void)?
    public var onReaderDismiss: (() -> Void)?
    public var onDismissWork: (() -> Void)?
    public var isVisible: Bool { panel.isVisible }
    public var hasLastAnswer: Bool { lastAnswer != nil }
    var displayedAnswer: String { originalAnswer }
    var displayedFrame: NSRect { panel.frame }
    var composerFrame: NSRect { bar.frame }
    var nativeGlassVisible: Bool { bar.usesGlass }
    var composerHasFocus: Bool { panel.firstResponder === input || panel.firstResponder === followup }
    private let panel: NonactivatingPanel
    private let root = FlippedView()
    private let bar = PanelSurface()
    private let reading = PanelSurface(role: .reading)
    private let identity = NSButton(title: "π", target: nil, action: nil)
    private let trusted = PanelStyle.label("Trusted pi", size: 10, weight: .medium)
    private let input = PromptEditor()
    private let inputScroll = NSScrollView()
    private let placeholder = PlaceholderLabel(labelWithString: "Ask about this window…")
    private let followup = PromptEditor()
    private let followupScroll = NSScrollView()
    private let followupPlaceholder = PlaceholderLabel(labelWithString: "Ask a follow-up…")
    private let activity = PanelStyle.label("Thinking…", size: 12, color: .labelColor)
    private let barStatus = PanelStyle.label("Saved answer", size: 12)
    private let progress = NSProgressIndicator()
    private let staticProgress = NSImageView()
    private let appIcon = NSImageView()
    private let sourceLabel = PanelStyle.label("", size: 11)
    private let questionLabel = PanelStyle.label("", size: 11)
    private let responseStatus = PanelStyle.label("", size: 11)
    private let result = NSTextView()
    private let answerScroll = NSScrollView()
    private let failureIcon = NSImageView()
    private let failureTitle = PanelStyle.label("", size: 16, weight: .semibold, color: .labelColor)
    private let failureMessage = NSTextField(wrappingLabelWithString: "")
    private lazy var ask = PanelButton("", symbol: "arrow.up", kind: .primary) { [weak self] in self?.submit() }
    private lazy var sendFollowup = PanelButton("", symbol: "arrow.up", kind: .primary) { [weak self] in self?.submitFollowup() }
    private lazy var close = PanelButton("", symbol: "xmark") { [weak self] in self?.escape() }
    private lazy var hideWork = PanelButton("", symbol: "minus") { [weak self] in self?.onDismissWork?() }
    private lazy var stop = PanelButton("", symbol: "stop.fill") { [weak self] in self?.onCancel?() }
    private lazy var openResult = PanelButton("Open", kind: .quiet) { [weak self] in self?.reopenLatestResult() }
    private lazy var copyButton = PanelButton("", symbol: "doc.on.doc") { [weak self] in self?.copyAnswer() }
    private lazy var permissions = PanelButton("Open Permissions…", kind: .filled) { [weak self] in self?.onPermissions?() }
    private let appearancePopover = NSPopover()
    private var workArea = Rect(x: 0, y: 0, width: 1440, height: 900)
    private var displayID: String?
    private var capability = "Read-only"
    private var isTrusted = false
    private var source = Source(app: "pi-os", title: "", icon: nil)
    private var question = ""
    private var originalAnswer = ""
    private var presentedFailure: FailurePresentation?
    private var lastAnswer: SavedAnswer?
    private var latestResult: (SavedAnswer, FailurePresentation?)?
    private var retryStatus: String?
    private var renderedCache: (text: String, scale: CGFloat, width: CGFloat, rendered: NSAttributedString, height: CGFloat)?
    private var copyReset: Task<Void, Never>?
    private var measurementStart: UInt64?
    private var changingState = false
    private struct Source { let app: String; let title: String; let icon: NSImage? }
    private struct SavedAnswer { let text: String; let question: String; let source: Source }

    public override init() {
        panel = NonactivatingPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 50),
            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        super.init()
        panel.delegate = self; panel.title = "pi-os"; panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.animationBehavior = .none; panel.isMovableByWindowBackground = false
        panel.autorecalculatesKeyViewLoop = true; panel.contentView = root
        panel.onEscape = { [weak self] in self?.escape() }
        panel.onCopyAnswer = { [weak self] in if self?.mode == .reader { self?.copyAnswer() } }
        root.addSubview(reading); root.addSubview(bar)
        if let screen = NSScreen.main { workArea = Rect(screen.visibleFrame) }
        for view in [identity, trusted, inputScroll, placeholder, followupScroll, followupPlaceholder,
                     ask, sendFollowup, activity, barStatus, progress, staticProgress, hideWork, stop, openResult] {
            bar.embedded.addSubview(view)
        }
        for view in [appIcon, sourceLabel, questionLabel, responseStatus, answerScroll,
                     failureIcon, failureTitle, failureMessage, close, copyButton, permissions] {
            reading.embedded.addSubview(view)
        }
        identity.isBordered = false; identity.font = .systemFont(ofSize: 22, weight: .medium)
        identity.image = PanelStyle.symbol("chevron.down", size: 8)
        identity.imagePosition = .imageTrailing; identity.target = self; identity.action = #selector(showContext)
        identity.setAccessibilityLabel("Pinned window and appearance")
        trusted.toolTip = "Global extensions and coding tools are not confined to this window."
        configureEditor(input, scroll: inputScroll, placeholder: placeholder, label: "Ask about the pinned window")
        configureEditor(followup, scroll: followupScroll, placeholder: followupPlaceholder, label: "Follow-up on the pinned window")
        input.submit = { [weak self] in self?.submit() }; input.dismiss = { [weak self] in self?.escape() }
        followup.submit = { [weak self] in self?.submitFollowup() }; followup.dismiss = { [weak self] in self?.escape() }
        result.isEditable = false; result.isSelectable = true; result.drawsBackground = false; result.isRichText = true
        result.isAutomaticLinkDetectionEnabled = false; result.textContainerInset = .zero
        result.textContainer?.lineFragmentPadding = 0; result.isHorizontallyResizable = false
        result.isVerticallyResizable = true; result.autoresizingMask = [.width]
        result.textContainer?.widthTracksTextView = true; result.setAccessibilityLabel("Answer")
        answerScroll.documentView = result; answerScroll.hasVerticalScroller = true
        answerScroll.autohidesScrollers = true; answerScroll.drawsBackground = false; answerScroll.borderType = .noBorder
        appIcon.imageScaling = .scaleProportionallyDown
        sourceLabel.lineBreakMode = .byTruncatingMiddle
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        staticProgress.image = PanelStyle.symbol("hourglass", size: 16); staticProgress.contentTintColor = PanelStyle.secondaryInk
        failureMessage.isSelectable = true; failureMessage.maximumNumberOfLines = 6
        failureMessage.lineBreakMode = .byWordWrapping
        for button in [ask, sendFollowup, close, stop, hideWork, copyButton] { button.rounded = true }
        ask.symbolSize = 17; sendFollowup.symbolSize = 17
        ask.toolTip = "Ask (Return)"; ask.setAccessibilityLabel("Ask")
        sendFollowup.toolTip = "Ask follow-up (Return)"; sendFollowup.setAccessibilityLabel("Ask follow-up")
        close.toolTip = "Close conversation (Escape)"; close.setAccessibilityLabel("Close conversation")
        stop.toolTip = "Cancel task"; stop.setAccessibilityLabel("Cancel task")
        hideWork.toolTip = "Continue in the background"; hideWork.setAccessibilityLabel("Hide task")
        copyButton.toolTip = "Copy original answer (⌘⇧C)"; copyButton.setAccessibilityLabel("Copy answer")
        appearancePopover.behavior = .semitransient; appearancePopover.animates = false
        appearancePopover.contentViewController = AppearanceViewController()
        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification, object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged), name: AppearanceSettings.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        applyAppearance()
        layoutCurrent()
    }
    private func configureEditor(_ editor: PromptEditor, scroll: NSScrollView, placeholder: NSTextField, label: String) {
        editor.textColor = .labelColor; editor.insertionPointColor = PanelStyle.accent
        editor.isRichText = false; editor.allowsUndo = true; editor.drawsBackground = false
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.textContainerInset = .zero; editor.textContainer?.lineFragmentPadding = 0
        editor.isHorizontallyResizable = false; editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.delegate = self; editor.setAccessibilityLabel(label)
        editor.setAccessibilityHelp("Return to ask. Shift-Return for a new line. Escape closes.")
        scroll.documentView = editor; scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        placeholder.textColor = PanelStyle.secondaryInk; placeholder.lineBreakMode = .byTruncatingTail
        placeholder.setAccessibilityElement(false)
    }
    private func applyAppearance() {
        panel.appearance = AppearanceSettings.shared.appearance
        appearancePopover.contentViewController?.view.appearance = AppearanceSettings.shared.appearance
        bar.updateColors(); reading.updateColors()
        let font = NSFont.systemFont(ofSize: PanelStyle.preferences.largerText ? 19 : 15)
        for editor in [input, followup] { editor.font = font; editor.insertionPointColor = PanelStyle.accent }
        placeholder.font = font; followupPlaceholder.font = font
        result.linkTextAttributes = [.foregroundColor: PanelStyle.accent, .underlineStyle: NSUnderlineStyle.single.rawValue]
        failureMessage.font = .systemFont(ofSize: 13 * PanelStyle.textScale); failureMessage.textColor = PanelStyle.secondaryInk
    }
    @objc private func appearanceChanged() {
        let responder = panel.firstResponder
        let selection = (responder as? NSTextView)?.selectedRange()
        renderedCache = nil
        applyAppearance(); layoutCurrent()
        // A visual preference switch must not clear a draft or dispose a conversation.
        if let editor = responder as? NSTextView, let selection {
            panel.makeFirstResponder(editor); editor.setSelectedRange(selection)
        }
    }
    @objc private func accessibilityChanged() { appearanceChanged(); if mode == .pill && isVisible { updateProgress() } }
    @objc private func screensChanged() {
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue == displayID }
            ?? NSScreen.screens.first { $0.frame.contains(NSPoint(x: panel.frame.midX, y: panel.frame.midY)) } ?? NSScreen.main
        if let screen { workArea = Rect(screen.visibleFrame) }
        layoutCurrent() // UI relocation only; never re-pin a native target.
    }
    private func escape() {
        if appearancePopover.isShown { appearancePopover.performClose(nil) } else { onCancel?() }
    }
    @objc private func showContext() { showAppearance() }
    @objc public func showAppearance() {
        guard isVisible, mode == .prompt || mode == .reader else { return }
        if appearancePopover.isShown { appearancePopover.performClose(nil); return }
        let controller = NSViewController(), appearance = AppearanceViewController()
        let container = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 370))
        controller.view = container; controller.addChild(appearance)
        let app = PanelStyle.label("Pinned: " + source.app, size: 12, weight: .semibold, color: .labelColor)
        app.frame = NSRect(x: 22, y: 16, width: 256, height: 18); container.addSubview(app)
        let title = PanelStyle.label(source.title, size: 11)
        title.toolTip = source.title; title.frame = NSRect(x: 22, y: 37, width: 256, height: 17); container.addSubview(title)
        let scope = PanelStyle.label(isTrusted ? "Trusted pi · tools are not window-confined" : capability + " · Target stays pinned", size: 10)
        scope.frame = NSRect(x: 22, y: 57, width: 256, height: 17); container.addSubview(scope)
        appearance.view.frame = NSRect(x: 0, y: 78, width: 300, height: 292); container.addSubview(appearance.view)
        container.appearance = AppearanceSettings.shared.appearance
        appearancePopover.contentViewController = controller
        appearancePopover.show(relativeTo: identity.bounds, of: identity, preferredEdge: .minY)
    }
    public func prewarm() {
        input.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        input.layoutManager?.ensureLayout(for: input.textContainer!)
        mode = .prompt; layoutCurrent(); changingState = true
        panel.alphaValue = 0; panel.orderFrontRegardless(); panel.displayIfNeeded(); panel.orderOut(nil); panel.alphaValue = 1
        mode = .hidden; changingState = false
    }
    public func measureNextVisibility(from start: UInt64) { measurementStart = start }
    @objc private func occlusionChanged() {
        guard let start = measurementStart, panel.occlusionState.contains(.visible) else { return }
        measurementStart = nil
        print("[perf] hotkey-to-visible-proxy ms=\(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)"); fflush(stdout)
    }
    private func reset(_ mode: Mode) {
        appearancePopover.close(); copyReset?.cancel(); copyReset = nil
        progress.stopAnimation(nil); self.mode = mode
        panel.acceptsKeys = mode == .prompt || mode == .reader
        panel.setAccessibilityLabel(mode == .reader ? "pi-os answer" : mode == .prompt ? "pi-os question" : "pi-os task")
        close.setAccessibilityLabel(mode == .reader ? "Close conversation" : "Dismiss")
        copyButton.image = PanelStyle.symbol("doc.on.doc"); copyButton.setAccessibilityLabel(presentedFailure == nil ? "Copy answer" : "Copy details")
        applyAppearance(); layoutCurrent()
    }
    public func prompt(snapshot: Snapshot, appName: String, canControl: Bool = false, trustedCompatibility: Bool = false) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let monitor = snapshot.monitors.first { $0.id == snapshot.targetWindow?.monitorId }
            ?? snapshot.monitors.first { $0.bounds.contains(snapshot.cursor) } ?? snapshot.monitors.first
        if let monitor { workArea = Placement.appKit(monitor.workArea, primaryHeight: primaryHeight); displayID = monitor.id }
        isTrusted = canControl && trustedCompatibility
        capability = canControl ? (isTrusted ? "Trusted pi" : snapshot.browser != nil ? "Brave tab" : "Can act") : "Read-only"
        source = Source(app: snapshot.targetWindow?.processName ?? appName, title: snapshot.targetWindow?.title ?? "",
            icon: snapshot.targetWindow.flatMap { NSRunningApplication(processIdentifier: $0.processId)?.icon })
        identity.toolTip = "Pinned: " + source.app + (source.title.isEmpty ? "" : " · " + source.title) + " — " + capability
        followupEnabled = false; followup.string = ""; followup.undoManager?.removeAllActions()
        input.string = ""; input.undoManager?.removeAllActions()
        question = ""; retryStatus = nil; presentedFailure = nil
        reset(.prompt); reveal(); panel.makeFirstResponder(input)
    }
    public func setDraft(_ text: String) { input.string = text; textDidChange(Notification(name: NSText.didChangeNotification)) }
    public func textDidChange(_ notification: Notification) { if mode == .prompt || mode == .reader { layoutCurrent() } }
    private func show(_ view: NSView, _ frame: NSRect) { view.frame = frame; view.isHidden = false }
    private var baseBarHeight: CGFloat { PanelStyle.preferences.largerText ? 62 : 50 }
    private func editorHeight(_ editor: NSTextView, width: CGFloat) -> CGFloat {
        let text = editor.string + (editor.string.hasSuffix("\n") ? " " : "")
        let measured = AnswerRenderer.measuredHeight(NSAttributedString(string: text, attributes: [.font: editor.font!]), width: width)
        return min(104, max(PanelStyle.preferences.largerText ? 30 : 24, measured))
    }
    private func frame(width: CGFloat, height: CGFloat) {
        panel.setFrame(Placement.bottomPanel(width: width, height: height, workArea: workArea,
            lowerInset: PanelStyle.preferences.lowerInset).cg, display: false)
        root.frame = NSRect(origin: .zero, size: panel.frame.size)
    }
    private func layoutCurrent() {
        guard !changingState else { return }
        // Hiding an active NSTextView's scroll view relinquishes first responder.
        // Never do that during per-keystroke layout; it can silently drop later text.
        bar.embedded.subviews.forEach {
            let activeInput = $0 === inputScroll && mode == .prompt
            let activeFollowup = $0 === followupScroll && mode == .reader && presentedFailure == nil && followupEnabled
            if !activeInput && !activeFollowup { $0.isHidden = true }
        }
        reading.embedded.subviews.forEach {
            if !($0 === answerScroll && mode == .reader && presentedFailure == nil) { $0.isHidden = true }
        }
        reading.isHidden = mode != .reader
        let width: CGFloat = min(PanelMetrics.width, CGFloat(max(1, workArea.width - 24)))
        let warningWidth: CGFloat = isTrusted ? 66 : 0
        let editorWidth = max(40, width - 116 - warningWidth)
        switch mode {
        case .prompt:
            let h = max(baseBarHeight, editorHeight(input, width: editorWidth) + 22)
            frame(width: width, height: h); bar.frame = root.bounds; bar.radius = 25
            layoutComposer(input, scroll: inputScroll, placeholder: placeholder, send: ask, width: editorWidth)
        case .reader:
            let hasComposer = presentedFailure == nil && followupEnabled
            let barHeight = hasComposer ? max(baseBarHeight, editorHeight(followup, width: editorWidth) + 22) : baseBarHeight
            let scale = PanelStyle.textScale
            let textWidth = max(1, width - 44)
            if renderedCache?.text != originalAnswer || renderedCache?.scale != scale || renderedCache?.width != textWidth {
                let rendered = AnswerRenderer.render(originalAnswer, scale: scale)
                renderedCache = (originalAnswer, scale, textWidth, rendered, AnswerRenderer.measuredHeight(rendered, width: textWidth))
            }
            let rendered = renderedCache!.rendered, bodyHeight = renderedCache!.height
            let top: CGFloat = question.isEmpty ? 49 : 78
            let requested: CGFloat
            if let failure = presentedFailure {
                let measured = AnswerRenderer.measuredHeight(NSAttributedString(string: failure.message, attributes: [.font: NSFont.systemFont(ofSize: 13 * scale)]), width: max(1, width - 76))
                requested = max(176, min(320, measured + 132))
            } else { requested = max(152, min(500, top + bodyHeight + 40)) }
            frame(width: width, height: requested + barHeight + 12)
            let readHeight = max(0, root.bounds.height - barHeight - 12)
            reading.frame = NSRect(x: 0, y: 0, width: root.bounds.width, height: readHeight); reading.radius = 21; reading.isHidden = false
            bar.frame = NSRect(x: 0, y: readHeight + 12, width: root.bounds.width, height: barHeight); bar.radius = 25
            layoutReader(rendered: rendered, bodyHeight: bodyHeight, top: top)
            if hasComposer { layoutComposer(followup, scroll: followupScroll, placeholder: followupPlaceholder, send: sendFollowup, width: editorWidth) }
            else {
                layoutIdentity()
                barStatus.stringValue = presentedFailure == nil ? "Saved answer · conversation closed" : "Request needs attention"
                show(barStatus, NSRect(x: 63, y: (barHeight - 18) / 2, width: width - 82, height: 18))
            }
        case .pill:
            frame(width: isTrusted ? 370 : 300, height: baseBarHeight); bar.frame = root.bounds; bar.radius = 25
            let w = bar.bounds.width, h = bar.bounds.height
            show(activity, NSRect(x: 42, y: (h - 18) / 2, width: w - 119 - warningWidth, height: 18))
            if isTrusted { show(trusted, NSRect(x: w - 135, y: (h - 16) / 2, width: 65, height: 16)) }
            show(hideWork, NSRect(x: w - 72, y: (h - 34) / 2, width: 34, height: 34))
            show(stop, NSRect(x: w - 39, y: (h - 34) / 2, width: 34, height: 34))
            progress.frame = NSRect(x: 17, y: (h - 16) / 2, width: 16, height: 16); staticProgress.frame = progress.frame
            if isVisible { updateProgress() }
        case .toast:
            frame(width: 340, height: baseBarHeight); bar.frame = root.bounds; bar.radius = 25
            let h = bar.bounds.height
            show(activity, NSRect(x: 18, y: (h - 18) / 2, width: 206, height: 18))
            show(openResult, NSRect(x: 235, y: (h - 34) / 2, width: 52, height: 34))
            // Close stays in the reader surface normally; reparent only for the toast.
            bar.embedded.addSubview(close); show(close, NSRect(x: 293, y: (h - 34) / 2, width: 34, height: 34))
        case .hidden: break
        }
        if mode != .toast && close.superview !== reading.embedded { reading.embedded.addSubview(close) }
        root.layoutSubtreeIfNeeded()
    }
    private func layoutIdentity() {
        show(identity, NSRect(x: 6, y: (bar.bounds.height - 42) / 2, width: 50, height: 42))
        if isTrusted { show(trusted, NSRect(x: 58, y: (bar.bounds.height - 16) / 2, width: 66, height: 16)) }
    }
    private func layoutComposer(_ editor: PromptEditor, scroll: NSScrollView, placeholder: NSTextField, send: PanelButton, width: CGFloat) {
        layoutIdentity()
        let h = bar.bounds.height, w = bar.bounds.width, x: CGFloat = isTrusted ? 128 : 62
        let editorH = min(editorHeight(editor, width: width), max(1, h - 22))
        show(scroll, NSRect(x: x, y: (h - editorH) / 2, width: width, height: editorH))
        let measured = AnswerRenderer.measuredHeight(NSAttributedString(string: editor.string + " ", attributes: [.font: editor.font!]), width: width)
        editor.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(editorH, measured)))
        show(placeholder, NSRect(x: x, y: (h - (PanelStyle.preferences.largerText ? 25 : 20)) / 2,
            width: width, height: PanelStyle.preferences.largerText ? 25 : 20))
        placeholder.isHidden = !editor.string.isEmpty
        send.isEnabled = !editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (mode == .prompt || followupEnabled)
        show(send, NSRect(x: w - 44, y: h - 41, width: 34, height: 34))
    }
    private func layoutReader(rendered: NSAttributedString, bodyHeight: CGFloat, top: CGFloat) {
        let w = reading.bounds.width, h = reading.bounds.height
        appIcon.image = source.icon ?? PanelStyle.symbol("macwindow", size: 14)
        show(appIcon, NSRect(x: 20, y: 18, width: 14, height: 14))
        sourceLabel.stringValue = source.app + (source.title.isEmpty ? "" : " · " + source.title); sourceLabel.toolTip = source.title
        show(sourceLabel, NSRect(x: 42, y: 17, width: max(0, w - 127), height: 18))
        show(close, NSRect(x: w - 40, y: 8, width: 32, height: 34))
        if let failure = presentedFailure {
            failureIcon.image = PanelStyle.symbol(failure.symbol, size: 21)
            failureTitle.stringValue = failure.title; failureMessage.stringValue = failure.message
            failureMessage.toolTip = originalAnswer
            show(failureIcon, NSRect(x: 21, y: 62, width: 23, height: 24))
            show(failureTitle, NSRect(x: 54, y: 59, width: w - 76, height: 25))
            show(failureMessage, NSRect(x: 54, y: 92, width: w - 76, height: max(0, h - 139)))
            if failure.offersPermissions { show(permissions, NSRect(x: 47, y: h - 39, width: 161, height: 30)) }
            else { show(copyButton, NSRect(x: w - 75, y: 8, width: 32, height: 34)) }
        } else {
            show(copyButton, NSRect(x: w - 75, y: 8, width: 32, height: 34))
            if !question.isEmpty {
                questionLabel.stringValue = question; questionLabel.toolTip = question
                show(questionLabel, NSRect(x: 22, y: 51, width: w - 44, height: 19))
            }
            if !result.attributedString().isEqual(to: rendered) { result.textStorage?.setAttributedString(rendered) }
            show(answerScroll, NSRect(x: 22, y: top, width: w - 44, height: max(0, h - top - 36)))
            result.setFrameSize(NSSize(width: answerScroll.contentSize.width, height: max(bodyHeight, answerScroll.contentSize.height)))
            responseStatus.stringValue = retryStatus ?? (followupEnabled ? "Ready for a follow-up · Same pinned window" : "Saved answer · Conversation closed")
            show(responseStatus, NSRect(x: 22, y: h - 25, width: w - 44, height: 17))
        }
    }
    private func submit() {
        let prompt = input.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode == .prompt, !prompt.isEmpty, prompt.utf16.count <= 20_000 else { return }
        question = prompt; onSubmit?(prompt)
    }
    public func setFollowupEnabled(_ enabled: Bool) { followupEnabled = enabled }
    public func setFollowupDraft(_ text: String) { followup.string = text; textDidChange(Notification(name: NSText.didChangeNotification)) }
    @discardableResult func submitFollowup() -> Bool {
        let prompt = followup.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode == .reader, presentedFailure == nil, followupEnabled, !prompt.isEmpty, prompt.utf16.count <= 20_000 else { return false }
        followupEnabled = false; sendFollowup.isEnabled = false
        question = prompt; followup.string = ""; followup.undoManager?.removeAllActions()
        onFollowup?(prompt); return true
    }
    public func restoreAfterFollowupFailure(_ error: Error, retry: Bool) {
        followupEnabled = retry
        guard let saved = lastAnswer else { showFailure(error); return }
        source = saved.source; question = saved.question
        retryStatus = retry ? "Follow-up failed — try again" : "Conversation ended — start a new task"
        responseStatus.toolTip = error.localizedDescription
        presentAnswer(saved.text, failure: nil, save: false, preserveRetry: true)
    }
    public func pill(_ text: String) {
        activity.stringValue = text; reset(.pill); stop.isEnabled = true
        panel.orderFrontRegardless(); panel.resignKey(); updateProgress()
    }
    private func updateProgress() {
        progress.isHidden = PanelStyle.reduceMotion; staticProgress.isHidden = !PanelStyle.reduceMotion
        if PanelStyle.reduceMotion { progress.stopAnimation(nil) } else { progress.startAnimation(nil) }
    }
    public func updateActivity(_ text: String) {
        guard mode == .pill else { return }
        activity.stringValue = text; activity.toolTip = text; stop.isEnabled = !text.hasPrefix("Cancelling")
        panel.setAccessibilityLabel("pi-os: " + text)
    }
    public func reader(_ text: String, failed: Bool = false, present: Bool = true) {
        presentAnswer(text, failure: failed ? FailurePresentation(DomainError("failed", text)) : nil, save: true, present: present)
    }
    public func showFailure(_ error: Error, present: Bool = true) {
        presentAnswer(error.localizedDescription, failure: FailurePresentation(error), save: true, present: present)
    }
    private func presentAnswer(_ text: String, failure: FailurePresentation?, save: Bool, present: Bool = true, preserveRetry: Bool = false) {
        originalAnswer = text; presentedFailure = failure
        if !preserveRetry { retryStatus = nil; responseStatus.toolTip = nil }
        if save {
            let saved = SavedAnswer(text: text, question: question, source: source)
            latestResult = (saved, failure); if failure == nil { lastAnswer = saved }
        }
        followup.string = ""; followup.undoManager?.removeAllActions()
        reset(.reader); result.setSelectedRange(NSRange(location: 0, length: 0)); result.scrollToBeginningOfDocument(nil)
        guard present else { panel.orderOut(nil); return }
        reveal(); panel.makeFirstResponder(failure == nil ? (followupEnabled ? followup : result) : nil)
        // No open/close or keyboard-triggered animations in this frequent-use surface.
    }
    public func dismissWorking() { guard mode == .pill else { return }; appearancePopover.close(); progress.stopAnimation(nil); panel.orderOut(nil) }
    public func suspendForInput() -> Bool { guard mode == .pill, isVisible else { return false }; dismissWorking(); return true }
    public func completionToast(failed: Bool) {
        activity.stringValue = failed ? "Request interrupted" : "Your answer is ready"; reset(.toast); panel.orderFrontRegardless()
    }
    public func reopenLatestResult() {
        guard let (saved, failure) = latestResult else { return }
        source = saved.source; question = saved.question; presentAnswer(saved.text, failure: failure, save: false)
    }
    public func reopenLastAnswer() {
        guard let saved = lastAnswer else { return }
        source = saved.source; question = saved.question; presentAnswer(saved.text, failure: nil, save: false)
    }
    public func reveal() {
        panel.recalculateKeyViewLoop(); panel.orderFrontRegardless()
        if panel.acceptsKeys { panel.makeKey() }
        if mode == .pill { updateProgress() }
    }
    public func hide() {
        appearancePopover.close(); copyReset?.cancel(); copyReset = nil; progress.stopAnimation(nil)
        changingState = true; panel.orderOut(nil); mode = .hidden; changingState = false
    }
    // Deactivation and outside clicks never dispose a retained conversation.
    public func windowDidResignKey(_ notification: Notification) {}
    private func copyAnswer() {
        guard mode == .reader else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(originalAnswer, forType: .string)
        copyButton.image = PanelStyle.symbol("checkmark"); copyButton.setAccessibilityLabel("Copied")
        NSAccessibility.post(element: copyButton, notification: .announcementRequested,
            userInfo: [.announcement: "Answer copied", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        copyReset?.cancel()
        copyReset = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_600_000_000) } catch { return }
            guard let self, self.mode == .reader else { return }
            self.copyButton.image = PanelStyle.symbol("doc.on.doc")
            self.copyButton.setAccessibilityLabel(self.presentedFailure == nil ? "Copy answer" : "Copy details")
        }
    }
    deinit {
        copyReset?.cancel(); NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
