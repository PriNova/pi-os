import AppKit
import ShellCore

@MainActor
private final class PanelDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class ShellPanel: NSPanel {
    var onEscape: (() -> Void)?
    private var placementPoint: CGPoint?
    func resetPlacement() { placementPoint = nil }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    init(title: String) {
        super.init(contentRect: .zero,
                   styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        self.title = title
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        isRestorable = false
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        animationBehavior = .none
        setAccessibilityLabel(title)
    }

    /// Uses display geometry and cursor location only. Never queries other
    /// windows, foreground-app metadata, selection, AX or screenshots.
    @discardableResult
    func present(views: [NSView], size: CGSize, takeKey: Bool, firstResponder: NSResponder? = nil) -> Bool {
        let screens = NSScreen.screens.enumerated().map {
            ScreenArea(id: $0.offset, frame: $0.element.frame, visibleFrame: $0.element.visibleFrame)
        }
        // Preserve the invocation's screen anchor across timer-driven modes;
        // a changed display topology is resolved against the current screens.
        let point = placementPoint ?? NSEvent.mouseLocation
        guard let screen = Placement.screen(at: point, among: screens),
              let frame = Placement.frame(size: size, on: screen) else { return false }
        placementPoint = point
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let document = PanelDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        contentView = scroll
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16)
        ] + views.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
        setFrame(frame, display: false)
        if takeKey {
            makeKeyAndOrderFront(nil)
            if let firstResponder { makeFirstResponder(firstResponder) }
        } else {
            // Do not make the reader key on an asynchronous completion.
            orderFrontRegardless()
        }
        return true
    }
}

@MainActor
enum UI {
    static func label(_ text: String, heading: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = heading ? .boldSystemFont(ofSize: 15) : .systemFont(ofSize: 12)
        label.textColor = heading ? .labelColor : .secondaryLabelColor
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    static func button(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        return button
    }

    static func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    static func reader(_ text: String) -> NSScrollView {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 230))
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.importsGraphics = false
        view.isAutomaticLinkDetectionEnabled = false
        view.font = .systemFont(ofSize: 13)
        view.textColor = .textColor
        view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.containerSize = NSSize(width: 480, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.string = text
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 230))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = view
        scroll.heightAnchor.constraint(equalToConstant: 230).isActive = true
        return scroll
    }
}
