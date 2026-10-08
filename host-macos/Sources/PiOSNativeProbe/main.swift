import AppKit
import PiOSCore
import PiOSMac

// Explicit controlled test runner, never installed in pi-os.app.
// With an explicit action file, exercises only the owned fixture through DesktopService.
struct FixtureState: Decodable {
    struct Window: Decodable { let name: String; let id: UInt32; let pid: Int32; let title: String; let bounds: Rect }
    let windows: [Window]
}
let args = CommandLine.arguments
guard args.count >= 2, ProcessInfo.processInfo.environment["PI_OS_NATIVE_TEST"] == "1" else {
    fputs("Usage: PI_OS_NATIVE_TEST=1 pi-os-native-probe <fixture-state.json> [action.json], after coordinating an idle desktop\n", stderr)
    exit(64)
}
_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)
_ = NSWorkspace.shared.frontmostApplication
struct ActionRequest: Decodable { let action: InputAction; let arguments: InputArguments }
let task = Task {
    do {
        let state = try JSONDecoder().decode(FixtureState.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        guard let window = state.windows.first(where: { $0.name == "A" }),
              NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier == "dev.pi-os.input-fixture" else {
            throw DomainError("invalid_fixture", "Probe only accepts its dedicated fixture app")
        }
        let target = WindowContext(windowID: window.id, pid: window.pid, name: "Fixture", title: window.title, bounds: window.bounds)
        if args.count > 2 {
            let request = try JSONDecoder().decode(ActionRequest.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
            let result = try await NativeFixtureProbe.run(target: target, action: request.action, arguments: request.arguments,
                directory: URL(fileURLWithPath: args[1]).deletingLastPathComponent()) {
                    print("CAPTURED"); fflush(stdout)
                    // Only the test parent's held pipe controls the post-capture test gate.
                    guard readLine() == "go" else { exit(2) }
                }
            // Keep the sender alive until WindowServer has dispatched its asynchronous posts.
            // The production host is resident and does not need this test-runner delay.
            try await Task.sleep(nanoseconds: 200_000_000)
            print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
        } else {
            _ = try await DesktopAX.focus(target)
            print("PASS: exact fixture window A raised and verified with public AX + CG APIs; no input posted")
        }
        exit(0)
    } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
}
withExtendedLifetime(task) { RunLoop.main.run() }
