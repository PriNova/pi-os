import Foundation

/// Local UI demonstration only. No invocation/context IDs, transport, prompt
/// history, models or persistence. A generation rejects late timer callbacks.
public struct DemoSession: Equatable, Sendable {
    public enum Reader: Equatable, Sendable { case demonstration, canceled, unsupported }
    public enum Phase: Equatable, Sendable {
        case closed, prompt, demonstrating(UInt64), reader(Reader)
    }
    public static let maximumPromptLength = 2_000
    public private(set) var phase: Phase = .closed
    public private(set) var validationMessage: String?
    private var generation: UInt64 = 0
    public init() {}

    public mutating func openPrompt() {
        generation &+= 1
        phase = .prompt
        validationMessage = nil
    }

    public mutating func submit(_ prompt: String) -> UInt64? {
        guard phase == .prompt else { return nil }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            validationMessage = "Enter a short sample prompt to demonstrate the shell."
            return nil
        }
        guard prompt.count <= Self.maximumPromptLength else {
            validationMessage = "Sample prompts are limited to 2,000 characters."
            return nil
        }
        generation &+= 1
        phase = .demonstrating(generation)
        validationMessage = nil
        return generation
    }

    @discardableResult
    public mutating func complete(generation token: UInt64) -> Bool {
        guard phase == .demonstrating(token) else { return false }
        phase = .reader(.demonstration)
        return true
    }

    public mutating func cancel() {
        generation &+= 1
        if case .demonstrating = phase { phase = .reader(.canceled) }
        else { phase = .closed }
        validationMessage = nil
    }

    public mutating func showUnsupported() {
        generation &+= 1
        phase = .reader(.unsupported)
        validationMessage = nil
    }

    public mutating func close() {
        generation &+= 1
        phase = .closed
        validationMessage = nil
    }

    public static func text(for reader: Reader) -> String {
        let heading: String
        switch reader {
        case .demonstration: heading = "Demonstration complete — this is fixed sample text, not an agent answer."
        case .canceled: heading = "Demonstration canceled — no agent or desktop action was running."
        case .unsupported: heading = "Experimental native-shell foundation — not a complete or usable agent Mac port."
        }
        return """
        \(heading)

        This shell has not read your screen, target application, selection, files or clipboard. Your sample prompt was not sent to a model or saved by the app.

        Screenshot/audio capture, Accessibility, desktop input, real models, agent transport, live sessions and follow-ups are unsupported. There is no HTTP listener or memory store.

        The Windows prompt/status/reader flow informs this demonstration; no Windows context or protocol compatibility is claimed. Closing the reader discards this local demonstration state. Nothing is copied to the clipboard automatically.
        """
    }
}
