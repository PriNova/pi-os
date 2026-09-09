import AppKit
import ShellCore

@MainActor
final class DemoController: NSObject, NSTextFieldDelegate {
    private let panel = ShellPanel(title: "pi-os — experimental shell demonstration")
    private var session = DemoSession()
    private var completion: DispatchWorkItem?
    private var prompt: NSTextField?
    private var validation: NSTextField?
    var onPresentationFailure: (() -> Void)?

    override init() {
        super.init()
        panel.onEscape = { [weak self] in self?.cancel() }
    }

    func openPrompt() {
        // Repeated hotkeys never replace an unsent draft or reset a running demo.
        if panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        completion?.cancel()
        panel.resetPlacement()
        session.openPrompt()
        let field = NSTextField(string: "")
        field.placeholderString = "Sample prompt — nothing will be sent or acted on"
        field.setAccessibilityLabel("Demonstration prompt")
        field.target = self
        field.action = #selector(submit)
        field.delegate = self
        let error = UI.label("")
        prompt = field
        validation = error
        present([
            UI.label("pi-os · Experimental native shell", heading: true),
            UI.label("Demonstration only. No screen context, agent, model or desktop actions."),
            field, error,
            UI.row([UI.button("Run demonstration", target: self, action: #selector(submit)),
                    UI.button("Cancel", target: self, action: #selector(cancel))]),
            UI.label("Enter: demonstrate · Escape: close · Up to 2,000 characters. Do not enter sensitive text.")
        ], size: CGSize(width: 540, height: 265), takeKey: true, firstResponder: field)
    }

    @objc private func submit() {
        guard let field = prompt, let generation = session.submit(field.stringValue) else {
            validation?.stringValue = session.validationMessage ?? ""
            return
        }
        // No prompt string is retained in the session, response or timer closure.
        field.stringValue = ""
        prompt = nil
        validation = nil
        panel.makeFirstResponder(nil)
        panel.resignKey()
        present([
            UI.label("Demonstration in progress — no agent running", heading: true),
            UI.label("A short local timer will display fixed sample text. Nothing is captured or executed."),
            UI.row([UI.button("Cancel demonstration", target: self, action: #selector(cancel)),
                    UI.button("Close", target: self, action: #selector(close))])
        ], size: CGSize(width: 540, height: 175), takeKey: false)
        guard session.phase == .demonstrating(generation) else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.session.complete(generation: generation) else { return }
                self.completion = nil
                self.showReader(takeKey: false)
            }
        }
        completion = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func showUnsupported() {
        completion?.cancel()
        completion = nil
        clearPrompt()
        panel.resetPlacement()
        session.showUnsupported()
        showReader(takeKey: true)
    }

    private func showReader(takeKey: Bool) {
        guard case .reader(let reader) = session.phase else { return }
        let followup = NSTextField(string: "")
        followup.placeholderString = "Follow-up unavailable — no live agent session"
        followup.isEnabled = false
        followup.setAccessibilityLabel("Follow-up unavailable: no live agent session")
        present([
            UI.label("pi-os · Demonstration / unsupported capabilities", heading: true),
            UI.reader(DemoSession.text(for: reader)),
            followup,
            UI.label("No automatic clipboard copy. Click the reader to select text. Escape or Close discards the demo."),
            UI.row([UI.button("New demonstration", target: self, action: #selector(newDemo)),
                    UI.button("Close", target: self, action: #selector(close))])
        ], size: CGSize(width: 540, height: 440), takeKey: takeKey)
    }

    @objc private func newDemo() {
        close()
        openPrompt()
    }

    @objc private func cancel() {
        completion?.cancel()
        completion = nil
        clearPrompt()
        session.cancel()
        if case .reader = session.phase { showReader(takeKey: false) }
        else { panel.orderOut(nil) }
    }

    @objc func close() {
        completion?.cancel()
        completion = nil
        clearPrompt()
        session.close()
        panel.orderOut(nil)
        panel.contentView = nil
    }

    private func clearPrompt() {
        prompt?.stringValue = ""
        prompt = nil
        validation = nil
    }

    private func present(_ views: [NSView], size: CGSize, takeKey: Bool, firstResponder: NSResponder? = nil) {
        if !panel.present(views: views, size: size, takeKey: takeKey, firstResponder: firstResponder) {
            close()
            onPresentationFailure?()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancel()
            return true
        }
        return false
    }
}
