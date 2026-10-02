import AppKit
import PiOSCore
import PiOSMac

// A TCC-free real NWListener fixture for Node hostClient/fetch conformance tests.
// Explicit CLI-only mode: it cannot enter the app's real desktop service.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--conformance" {
    do {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        let env = ProcessInfo.processInfo.environment
        guard let token = env["PI_OS_TOKEN"], !token.isEmpty,
              let port = UInt16(env["PI_OS_HOST_PORT"] ?? "17831") else { throw DomainError("configuration_error", "Token and port required") }
        let server = try LoopbackServer(port: port) { request in
            if request.method == "GET", request.path == "/health" { return .json(["service": "macos-conformance"]) }
            guard HostRoutes.authorized(request.headers["x-harness-token"], token: token) else {
                return .error(401, "unauthorized", "Missing or wrong X-Harness-Token")
            }
            if request.method == "GET", request.path == "/tools" { return HostRoutes.catalog() }
            guard request.method == "POST", request.path.hasPrefix("/tools/"),
                  HostRoutes.names.contains(String(request.path.dropFirst(7))) else {
                return .error(404, "not_found", "Unknown route")
            }
            guard let args = try? JSONDecoder().decode(HostRoutes.ToolArguments.self, from: request.body) else {
                return .error(400, "invalid_arguments", "Expected arguments.contextId")
            }
            if args.arguments.contextId != snapshot.id {
                return .json(ToolOutcome<Snapshot>.failure(DomainError("unknown_context", "Unknown context")))
            }
            if request.path == "/tools/desktop.captureWindow" {
                guard let shot = snapshot.screenshot else {
                    return .json(ToolOutcome<ScreenshotRef>.failure(DomainError("no_target", "No screenshot in fixture")))
                }
                return .json(ToolOutcome.success(shot))
            }
            return .json(ToolOutcome.success(snapshot))
        }
        server.onFailure = { message in fputs(message + "\n", stderr); exit(1) }
        server.start { print("READY"); fflush(stdout) }
        withExtendedLifetime(server) { RunLoop.main.run() }
    } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = Application()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
