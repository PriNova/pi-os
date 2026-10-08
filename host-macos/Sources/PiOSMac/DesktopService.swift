import AppKit
import CoreGraphics
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers
import PiOSCore

extension Rect {
    init(_ r: CGRect) { self.init(x: r.minX, y: r.minY, width: r.width, height: r.height) }
    var cg: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

public enum DesktopIdentity {
    public static func windows(includeDesktop: Bool = false) -> [[String: Any]] {
        let options: CGWindowListOption = includeDesktop ? [.optionOnScreenOnly] : [.optionOnScreenOnly, .excludeDesktopElements]
        return CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    }
    static func finderDesktop(_ info: [String: Any]) -> Bool {
        guard (info[kCGWindowLayer as String] as? Int) == FinderDesktop.layer,
              let pid = info[kCGWindowOwnerPID as String] as? Int32 else { return false }
        return FinderDesktop.eligible(pid: pid)
    }
    static func normal(_ info: [String: Any]) -> Bool {
        (info[kCGWindowLayer as String] as? Int) == 0 && (info[kCGWindowOwnerPID as String] as? Int32) != getpid()
    }
    static func bounds(_ info: [String: Any]) -> Rect? {
        guard let dict = info[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: dict) else { return nil }
        let rect = Rect(frame)
        return rect.valid ? rect : nil
    }
    static func window(_ info: [String: Any], monitors: [Monitor]) -> WindowContext? {
        let desktop = finderDesktop(info)
        guard normal(info) || desktop, let id = info[kCGWindowNumber as String] as? UInt32,
              let pid = info[kCGWindowOwnerPID as String] as? Int32, let rect = bounds(info) else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        var context = WindowContext(windowID: id, pid: pid,
                             name: app?.localizedName ?? info[kCGWindowOwnerName as String] as? String ?? "Application",
                             title: info[kCGWindowName as String] as? String ?? "", bounds: rect,
                             executablePath: app?.executableURL?.path,
                             monitorId: monitors.max(by: {
                                 $0.bounds.cg.intersection(rect.cg).area < $1.bounds.cg.intersection(rect.cg).area
                             })?.id)
        if desktop {
            context.surface = FinderContextPolicy.desktopSurface; context.title = "Desktop"
            context.desktopWorkArea = monitors.first { $0.id == context.monitorId }?.workArea
            context.shellFolderPath = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path
        }
        return context
    }
    /// No SCK or AX on this path. Call before showing the nonactivating panel.
    public static func pin() -> Snapshot {
        precondition(Thread.isMainThread)
        let frontApp = NSWorkspace.shared.frontmostApplication
        let front = frontApp?.processIdentifier
        let finder = frontApp?.bundleIdentifier == "com.apple.finder"
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let monitors = NSScreen.screens.compactMap { screen -> Monitor? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = number.uint32Value
            return Monitor(id: String(id), name: screen.localizedName, primary: id == CGMainDisplayID(),
                           bounds: Rect(CGDisplayBounds(id)),
                           workArea: Placement.appKit(Rect(screen.visibleFrame), primaryHeight: primaryHeight))
        }
        let cursor = CGEvent(source: nil)?.location ?? .zero
        let point = Point(x: cursor.x, y: cursor.y)
        let list = windows(includeDesktop: finder)
        let normalTarget = list.first { normal($0) && ($0[kCGWindowOwnerPID as String] as? Int32) == front }
            .flatMap { window($0, monitors: monitors) }
        let desktopCandidates = finder ? list.filter { finderDesktop($0) && ($0[kCGWindowOwnerPID as String] as? Int32) == front && bounds($0)?.contains(point) == true } : []
        let desktop = desktopCandidates.count == 1 ? window(desktopCandidates[0], monitors: monitors) : nil
        let target: WindowContext?
        if let desktop, normalTarget == nil || FinderDesktop.focusedAtPin(desktop) { target = desktop }
        else { target = normalTarget }
        let under = list.first { (normal($0) || finderDesktop($0)) && bounds($0)?.contains(point) == true }
            .flatMap { window($0, monitors: monitors) }
        return Snapshot(cursor: point, target: target, underCursor: under, monitors: monitors)
    }
    /// Public ID + PID revalidation. Existence is deliberately independent of on-screen status.
    static func revalidate(_ target: WindowContext) throws -> Rect {
        guard let id = target.windowID,
              let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let info = list.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == id }),
              (info[kCGWindowOwnerPID as String] as? Int32) == target.processId,
              (FinderDesktop.isDesktop(target) ? finderDesktop(info) : normal(info)) else {
            throw DomainError("target_gone", "The pinned window closed or its owner changed")
        }
        guard let bounds = bounds(info) else {
            throw DomainError("capture_failed", "The pinned window exists but has no capturable frame")
        }
        return bounds
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}

/// Lazy TTL and size eviction only: there is no resident sweep timer.
public actor DesktopService {
    struct Entry {
        var snapshot: Snapshot
        var transform: CaptureTransform?
        var files: [String] = []
        var expires: Date
        var fingerprint: ProcessFingerprint?
        var browserPin: BrowserPin?
        var coordinatesFresh = false
        var inputUncertain = false
        var budget = InputBudget()
        let lease: ContextLease
    }
    private let gate = OperationGate()
    private var actions: [String: Task<InputResult, Error>] = [:]
    private let controlEnabled: () -> Bool
    private let beforeInput: () async -> Bool
    private let afterInput: (Bool) async -> Void
    private let traceFile: URL?
    private var entries: [String: Entry] = [:]
    private var pending: [String: Task<Captured, Error>] = [:]
    private let captures: URL
    private let token: String
    private let launched = Date()
    private let ttl: TimeInterval
    private let capacity: Int

    public init(captures: URL, token: String, ttl: TimeInterval = 1800, capacity: Int = 32,
                controlEnabled: @escaping () -> Bool = { false }, traceFile: URL? = nil,
                beforeInput: @escaping () async -> Bool = { false }, afterInput: @escaping (Bool) async -> Void = { _ in }) {
        self.captures = captures; self.token = token; self.ttl = ttl; self.capacity = capacity
        self.controlEnabled = controlEnabled; self.traceFile = traceFile
        self.beforeInput = beforeInput; self.afterInput = afterInput
    }
    public func insert(_ snapshot: Snapshot, browserPin: BrowserPin? = nil) {
        for (id, entry) in entries where entry.expires <= Date() { remove(id) }
        if entries.count >= capacity, let oldest = entries.min(by: { $0.value.expires < $1.value.expires })?.key { remove(oldest) }
        let expires = Date().addingTimeInterval(ttl)
        entries[snapshot.id] = Entry(snapshot: snapshot, expires: expires,
                                     fingerprint: snapshot.targetWindow.flatMap { NativeDesktopDriver.fingerprint($0.processId) },
                                     browserPin: browserPin, lease: ContextLease(expires: expires))
    }
    public func remove(_ id: String) {
        pending.removeValue(forKey: id)?.cancel()
        actions.removeValue(forKey: id)?.cancel()
        if let entry = entries.removeValue(forKey: id) {
            entry.lease.revoke()
            for file in entry.files { try? FileManager.default.removeItem(atPath: file) }
        }
    }
    public func removeAll() { for id in Array(entries.keys) { remove(id) } }
    private func entry(_ id: String) throws -> Entry {
        guard let entry = entries[id], entry.expires > Date() else {
            remove(id); throw DomainError("unknown_context", "The pinned context expired or was cancelled")
        }
        if let target = entry.snapshot.targetWindow { _ = try DesktopIdentity.revalidate(target) }
        return entry
    }
    public func snapshot(_ id: String) throws -> Snapshot { try entry(id).snapshot }

    public func capture(_ id: String) async throws -> ScreenshotRef {
        do { try await gate.acquire() } catch { throw DomainError("busy", "Capture cancelled while waiting") }
        do {
            let shot = try await captureLocked(id)
            await gate.release(); return shot
        } catch { await gate.release(); throw error }
    }
    private func captureLocked(_ id: String) async throws -> ScreenshotRef {
        try Task.checkCancellation()
        let entry = try entry(id)
        guard let target = entry.snapshot.targetWindow else {
            throw DomainError("no_target", "The frontmost application has no capturable window. Open a window and try again.")
        }
        if let browserPin = entry.browserPin { _ = try browserPin.verify(target) }
        // A capture is a serialized context mutation (latest screenshot + transform).
        // Refuse overlap rather than allowing an older completion to overwrite a newer one.
        guard pending[id] == nil else { throw DomainError("busy", "A capture of this context is already in progress") }
        let directory = captures
        let job = Task.detached(priority: .userInitiated) { try await Self.captureWindow(target, directory: directory) }
        pending[id] = job
        var producedFile: String?
        do {
            let captured = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
            producedFile = captured.shot.filePath
            try Task.checkCancellation()
            guard var current = entries[id], current.expires > Date() else {
                try? FileManager.default.removeItem(atPath: captured.shot.filePath!)
                throw DomainError("unknown_context", "Capture was cancelled or expired")
            }
            _ = try DesktopIdentity.revalidate(target)
            if let browserPin = current.browserPin { _ = try browserPin.verify(target) }
            current.snapshot.screenshot = captured.shot
            current.snapshot.targetWindow?.bounds = captured.transform.frame
            current.snapshot.targetWindow?.title = FinderDesktop.isDesktop(target) ? "Desktop" : captured.title
            current.snapshot.foregroundWindow?.bounds = captured.transform.frame
            current.snapshot.foregroundWindow?.title = FinderDesktop.isDesktop(target) ? "Desktop" : captured.title
            FinderDesktop.enrich(&current.snapshot)
            DesktopAX.enrichWindowDocument(&current.snapshot)
            current.snapshot.capturedAt = ISO8601DateFormatter().string(from: Date())
            current.transform = captured.transform
            current.coordinatesFresh = true
            if let path = captured.shot.filePath, !current.files.contains(path) { current.files.append(path) }
            while current.files.count > 8 { try? FileManager.default.removeItem(atPath: current.files.removeFirst()) }
            entries[id] = current; pending[id] = nil
            return captured.shot
        } catch {
            pending[id] = nil
            if let path = producedFile { try? FileManager.default.removeItem(atPath: path) }
            if let domain = error as? DomainError { throw domain }
            if error is CancellationError { throw DomainError("busy", "Capture cancelled") }
            throw DomainError("capture_failed", "macOS could not capture the pinned window. Check Screen Recording permission and window visibility.")
        }
    }

    private struct Captured { let shot: ScreenshotRef; let transform: CaptureTransform; let title: String }
    private static func captureWindow(_ target: WindowContext, directory: URL) async throws -> Captured {
        _ = try DesktopIdentity.revalidate(target)
        guard CGPreflightScreenCaptureAccess() else {
            throw DomainError("permission_denied", "Allow Screen Recording from the pi-os menu → Permissions…, then relaunch pi-os if macOS requests it.")
        }
        for attempt in 0...1 {
            try Task.checkCancellation()
            let enumerationStart = DispatchTime.now().uptimeNanoseconds
            let content: SCShareableContent = try await Deadline.call(seconds: 5) { done in
                SCShareableContent.getExcludingDesktopWindows(!FinderDesktop.isDesktop(target), onScreenWindowsOnly: false) { content, error in
                    if let content { done(.success(content)) }
                    else { done(.failure(error ?? DomainError("capture_failed", "Window enumeration failed"))) }
                }
            }
            guard let window = content.windows.first(where: { $0.windowID == target.windowID && $0.owningApplication?.processID == target.processId }) else {
                _ = try DesktopIdentity.revalidate(target)
                throw DomainError("capture_failed", "The window exists but is unavailable for capture (minimized or off-Space)")
            }
            let frame = Rect(window.frame)
            guard frame.valid, frame.width <= 16_384, frame.height <= 16_384, frame.width * frame.height <= 16_777_216 else {
                throw DomainError("capture_failed", "Window geometry is invalid or too large")
            }
            let configuration = SCStreamConfiguration()
            let pixels = CaptureSizing.pixels(for: frame)
            configuration.width = pixels.width
            configuration.height = pixels.height
            configuration.scalesToFit = true
            configuration.ignoreShadowsSingleWindow = true
            configuration.showsCursor = false
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let captureStart = DispatchTime.now().uptimeNanoseconds
            let image: CGImage = try await Deadline.call(seconds: 5) { done in
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                    if let image { done(.success(image)) }
                    else { done(.failure(error ?? DomainError("capture_failed", "Window capture failed"))) }
                }
            }
            if ProcessInfo.processInfo.environment["PI_OS_PERF"] == "1" {
                let end = DispatchTime.now().uptimeNanoseconds
                print("[perf] enumerate ms=\(Double(captureStart - enumerationStart) / 1_000_000) capture ms=\(Double(end - captureStart) / 1_000_000) image=\(image.width)x\(image.height)")
                fflush(stdout)
            }
            try Task.checkCancellation()
            let after = try DesktopIdentity.revalidate(target)
            if after != frame {
                if attempt == 0 { continue }
                throw DomainError("capture_failed", "Window moved or resized during capture; try again")
            }
            let transform = try CaptureTransform(frame: frame, imageWidth: image.width, imageHeight: image.height)
            let id = "shot-" + UUID().uuidString
            let file = directory.appendingPathComponent(id + ".png")
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                throw DomainError("capture_failed", "PNG encoder unavailable")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination), data.length <= 8 * 1024 * 1024 else {
                throw DomainError("capture_failed", "Screenshot exceeds the PNG size limit")
            }
            try Task.checkCancellation()
            try (data as Data).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return Captured(shot: ScreenshotRef(filePath: file.path, imageId: id, bounds: frame, imageWidth: image.width, imageHeight: image.height), transform: transform, title: window.title ?? "")
        }
        throw DomainError("capture_failed", "Capture did not stabilize")
    }

    public func act(_ action: InputAction, arguments: InputArguments) async throws -> InputResult {
        do { try await gate.acquire() } catch { throw DomainError("busy", "Input cancelled while waiting") }
        let started = Date()
        var hidden = false
        do {
            try Task.checkCancellation()
            guard controlEnabled() else { throw DomainError("control_disabled", "Computer control needs a signed app and Accessibility/Input permission") }
            var current = try entry(arguments.contextId)
            guard !current.inputUncertain else { throw DomainError("input_failed", "A previous input outcome was uncertain. Inspect the window and start a new task; this context cannot post more input.") }
            guard current.snapshot.browser == nil else { throw DomainError("browser_route_required", "This invocation is bound to a Brave tab. Use browser tools; native input is unavailable in this task.") }
            guard let target = current.snapshot.targetWindow else { throw DomainError("no_target", "There is no pinned window to control") }
            guard let fingerprint = current.fingerprint else { throw DomainError("policy_blocked", "The pinned process ownership could not be established") }
            try action.validate(arguments)
            if action == .click || (action == .scroll && arguments.x != nil) {
                guard let screenshotId = arguments.screenshotId, screenshotId == current.snapshot.screenshot?.imageId,
                      current.coordinatesFresh else {
                    throw DomainError("capture_stale", "The agent must view the latest screenshot before coordinate input")
                }
            }
            try current.budget.reserve(action, arguments: arguments)
            entries[arguments.contextId] = current
            hidden = await beforeInput()
            let enabled = controlEnabled
            let state = current
            let job = Task.detached(priority: .userInitiated) {
                let controller = DesktopInputController(driver: NativeDesktopDriver(fingerprint: fingerprint), enabled: enabled)
                return try await controller.execute(action, args: arguments, target: target, transform: state.transform,
                                                    coordinatesFresh: state.coordinatesFresh, lease: state.lease)
            }
            actions[arguments.contextId] = job
            let result = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
            actions[arguments.contextId] = nil
            if action != .focus { entries[arguments.contextId]?.coordinatesFresh = false }
            await afterInput(hidden)
            trace(action, outcome: "posted", result: result, started: started)
            await gate.release(); return result
        } catch {
            actions[arguments.contextId] = nil
            if (error as? DomainError)?.code == "input_failed" { entries[arguments.contextId]?.inputUncertain = true }
            if action != .focus { entries[arguments.contextId]?.coordinatesFresh = false }
            await afterInput(hidden)
            trace(action, outcome: (error as? DomainError)?.code ?? "cancelled", result: nil, started: started)
            await gate.release()
            if error is CancellationError { throw DomainError("busy", "Input cancelled while waiting") }
            throw error
        }
    }
    private func trace(_ action: InputAction, outcome: String, result: InputResult?, started: Date) {
        guard let traceFile else { return }
        // No prompt, typed text, key values, window titles, or context capabilities in traces.
        var row: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date()), "action": action.name,
                                  "outcome": outcome, "durationMs": Int(Date().timeIntervalSince(started) * 1000)]
        if let result { row["postedEvents"] = result.postedEvents; row["characters"] = result.characters }
        guard var bytes = try? JSONSerialization.data(withJSONObject: row) else { return }
        bytes.append(10)
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: traceFile.path)[.size]) as? Int, size > 2_000_000 {
            try? fm.removeItem(at: traceFile.appendingPathExtension("previous"))
            try? fm.moveItem(at: traceFile, to: traceFile.appendingPathExtension("previous"))
        }
        if !fm.fileExists(atPath: traceFile.path) { fm.createFile(atPath: traceFile.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        if let handle = try? FileHandle(forWritingTo: traceFile) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: bytes)
        }
    }

    /// Native identity/permission/selected-tab gate for the first-party CDP adapter.
    /// This route never accepts a target ID, endpoint URL or executable from the model.
    private func browserConnection(_ args: BrowserArguments) async throws -> BrowserConnection {
        try await gate.acquire()
        do {
            try Task.checkCancellation()
            guard controlEnabled() else { throw DomainError("control_disabled", "Brave connection requires computer-control permission") }
            var current = try entry(args.contextId)
            try current.lease.check()
            guard let target = current.snapshot.targetWindow, current.snapshot.browser != nil,
                  let pin = current.browserPin, let fingerprint = current.fingerprint else {
                throw DomainError("browser_tab_unknown", "No Brave tab was pinned. Enable Brave connection in Settings, show a normal page and start a new task.")
            }
            guard fingerprint.bundleID == BrowserPolicy.bundleID else { throw DomainError("policy_blocked", "Not a Brave context") }
            _ = try NativeDesktopDriver(fingerprint: fingerprint).inspect(target)
            if args.mutation == true {
                guard !current.inputUncertain else { throw DomainError("input_failed", "An earlier outcome was uncertain; start a new task") }
                try BrowserPolicy.validateBudget(args, budget: &current.budget)
                entries[args.contextId] = current
                _ = await beforeInput()
                try await pin.focus(target)
                try Task.checkCancellation(); try current.lease.check()
                guard controlEnabled() else { throw DomainError("control_disabled", "Computer control was disabled") }
                _ = try NativeDesktopDriver(fingerprint: fingerprint).inspect(target)
                entries[args.contextId]?.coordinatesFresh = false
            }
            let result = try pin.verify(target)
            await gate.release(); return result
        } catch { await gate.release(); throw error }
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        if request.method == "GET", request.path == "/health" {
            struct Health: Encodable { let service = "macos-host"; let version = "0.1.0"; let uptimeSeconds: Int }
            return .json(Health(uptimeSeconds: Int(Date().timeIntervalSince(launched))))
        }
        guard HostRoutes.authorized(request.headers["x-harness-token"], token: token) else {
            return .error(401, "unauthorized", "Missing or wrong X-Harness-Token")
        }
        if request.method == "GET", request.path == "/tools" { return HostRoutes.catalog(includeInput: controlEnabled()) }
        if request.method == "POST", ["/tools/browser.connection", "/tools/browser.validate", "/tools/browser.invalidate"].contains(request.path) {
            struct Body: Decodable { let arguments: BrowserArguments }
            guard let args = try? JSONDecoder().decode(Body.self, from: request.body).arguments, !args.contextId.isEmpty else {
                return .error(400, "invalid_arguments", "Expected a browser context")
            }
            if request.path == "/tools/browser.invalidate" {
                entries[args.contextId]?.inputUncertain = true
                return .json(ToolOutcome.success(true))
            }
            do { return .json(ToolOutcome.success(try await browserConnection(args))) }
            catch { return .json(ToolOutcome<BrowserConnection>.failure(error as? DomainError ?? DomainError("browser_unavailable", "Brave connection could not be validated"))) }
        }
        if request.method == "POST", request.path.hasPrefix("/tools/"), let action = InputAction(rawValue: String(request.path.dropFirst(7))) {
            struct Body: Decodable { let arguments: InputArguments }
            guard let body = try? JSONDecoder().decode(Body.self, from: request.body), !body.arguments.contextId.isEmpty else {
                return .error(400, "invalid_arguments", "Expected arguments.contextId and valid input parameters")
            }
            do { return .json(ToolOutcome.success(try await act(action, arguments: body.arguments))) }
            catch { return .json(ToolOutcome<InputResult>.failure(error as? DomainError ?? DomainError("internal_error", "Native input could not complete"))) }
        }
        guard request.method == "POST", request.path.hasPrefix("/tools/"),
              HostRoutes.names.contains(String(request.path.dropFirst(7))) else {
            return .error(404, "not_found", "Unknown read-only host route")
        }
        guard let args = try? JSONDecoder().decode(HostRoutes.ToolArguments.self, from: request.body),
              !args.arguments.contextId.isEmpty else {
            return .error(400, "invalid_arguments", "Expected arguments.contextId")
        }
        let id = args.arguments.contextId
        do {
            try Task.checkCancellation()
            switch String(request.path.dropFirst(7)) {
            case "desktop.captureWindow": return .json(ToolOutcome.success(try await capture(id)))
            case "desktop.refreshContext":
                _ = try await capture(id)
                // Metadata refresh is not visual verification. Its image has not been
                // delivered to the model, so it cannot authorize coordinate input.
                entries[id]?.coordinatesFresh = false
                var refreshed = try snapshot(id)
                DesktopAX.refreshFocusedMetadata(&refreshed)
                entries[id]?.snapshot = refreshed
                return .json(ToolOutcome.success(refreshed))
            default: return .json(ToolOutcome.success(try snapshot(id)))
            }
        } catch {
            return .json(ToolOutcome<Snapshot>.failure(error as? DomainError ?? DomainError("busy", "Operation cancelled")))
        }
    }
}
