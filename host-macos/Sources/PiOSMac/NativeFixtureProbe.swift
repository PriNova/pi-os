import AppKit
import PiOSCore

/// Controlled QA entry point. It cannot target an arbitrary application and is not a host route.
public enum NativeFixtureProbe {
    public static func run(target: WindowContext, action: InputAction, arguments: InputArguments,
                           directory: URL, captured: () -> Void) async throws -> InputResult {
        guard NativeDesktopDriver.fingerprint(target.processId)?.bundleID == "dev.pi-os.input-fixture" else {
            throw DomainError("invalid_fixture", "Native probe only accepts the dedicated input fixture")
        }
        let service = DesktopService(captures: directory, token: "fixture-only", controlEnabled: { true },
                                     traceFile: directory.appendingPathComponent("actions.jsonl"))
        let snapshot = Snapshot(id: arguments.contextId, cursor: Point(x: 0, y: 0), target: target, underCursor: nil, monitors: [])
        await service.insert(snapshot)
        do {
            let shot = try await service.capture(snapshot.id)
            if let path = shot.filePath {
                let evidence = directory.appendingPathComponent("screenshot.png")
                try? FileManager.default.removeItem(at: evidence)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: evidence)
            }
            captured()
            var bound = arguments
            bound.screenshotId = shot.imageId
            let result = try await service.act(action, arguments: bound)
            await service.removeAll()
            return result
        } catch { await service.removeAll(); throw error }
    }
}
