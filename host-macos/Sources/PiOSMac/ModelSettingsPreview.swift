import AppKit

/// Standalone UI fixture; no SDK, provider discovery or model calls.
@MainActor public enum ModelSettingsPreview {
    private static var controller: SettingsWindow?
    private final class Service: ModelSettingsService {
        func reserve() -> UUID { UUID() }
        func release(_ id: UUID) {}
        func models() async throws -> HarnessClient.ModelCatalog {
            HarnessClient.ModelCatalog(models: [
                .init(provider: "Preview", id: "fast", name: "Fast model", thinkingLevels: ["off", "low"]),
                .init(provider: "Preview", id: "reasoning", name: "Reasoning model", thinkingLevels: ["low", "medium", "high", "xhigh"]),
                .init(provider: "Another provider", id: "default", name: "General model", thinkingLevels: ["off"]),
            ], current: .init(provider: "Preview", modelId: "reasoning", thinkingLevel: "high"))
        }
        func setModel(_ selection: HarnessClient.ModelSelection) async throws { /* preview only */ }
        func resources() async throws -> HarnessClient.ResourceSettings { .init(current: .init(mode: "isolated"), warning: "Mock preview only") }
        func setResources(trusted: Bool) async throws { /* preview only; no code loaded */ }
    }
    public static func show() {
        let window = SettingsWindow(harness: Service(), notifier: ResultNotifier())
        controller = window
        window.window?.title = "pi-os Settings — Mock Preview"
        window.onClosed = { controller = nil; NSApp.terminate(nil) }
        window.present()
    }
}
