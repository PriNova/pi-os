import XCTest
@testable import PiOSCore
@testable import PiOSMac

private final class FakeInputDriver: DesktopInputDriver {
    var frame = Rect(x: -800, y: 100, width: 800, height: 600)
    var inspectError: DomainError?
    var focusError: DomainError?
    var securityError: DomainError?
    var covered = false
    var destructivePoint = false
    var allocationFails = false
    var events: [NativeInputEvent] = []
    var focused = 0
    var onPost: (() -> Void)?
    func inspect(_ target: WindowContext) throws -> Rect { if let inspectError { throw inspectError }; return frame }
    func focus(_ target: WindowContext) async throws { if let focusError { throw focusError }; focused += 1 }
    func validateFocusAndSecurity(_ target: WindowContext, action: InputAction, arguments: InputArguments) throws { if let securityError { throw securityError } }
    func validatePoint(_ point: Point, target: WindowContext) throws {
        if covered { throw DomainError("focus_failed", "Covered") }
    }
    func validateActionPoint(_ point: Point, target: WindowContext, action: InputAction) throws {
        if destructivePoint && action == .click { throw DomainError("file_deletion_blocked", "Delete control") }
    }
    func keyCode(_ key: String, command: Bool) throws -> UInt16 { KeyboardMapping.named[key] ?? 0 }
    func prepare(_ event: NativeInputEvent, pid: pid_t) throws -> () -> Void {
        if allocationFails { throw DomainError("input_failed", "Allocation failed") }
        return { self.events.append(event); self.onPost?() }
    }
}

final class InputTests: XCTestCase {
    let target = WindowContext(windowID: 123, pid: 456, name: "fixture", title: "fixture",
                               bounds: Rect(x: -800, y: 100, width: 800, height: 600))
    func transform() throws -> CaptureTransform { try CaptureTransform(frame: target.bounds, imageWidth: 400, imageHeight: 300) }
    func lease() -> ContextLease { ContextLease(expires: Date().addingTimeInterval(60)) }

    func testRefusalMatrixPostsZeroEvents() async throws {
        for code in ["target_gone", "target_elevated", "policy_blocked", "accessibility_denied", "input_permission_denied", "secure_input", "focus_unknown"] {
            let driver = FakeInputDriver(); driver.inspectError = DomainError(code, "rejected")
            do {
                _ = try await DesktopInputController(driver: driver).execute(.click, args: .init(contextId: "x", x: 20, y: 20),
                    target: target, transform: transform(), lease: lease())
                XCTFail(code)
            } catch { XCTAssertEqual((error as? DomainError)?.code, code) }
            XCTAssertTrue(driver.events.isEmpty, code)
        }
        for code in ["focus_failed", "focus_unknown", "secure_input"] {
            let driver = FakeInputDriver(); driver.securityError = DomainError(code, "rejected after focus")
            do {
                _ = try await DesktopInputController(driver: driver).execute(.typeText, args: .init(contextId: "x", text: "never posted"),
                    target: target, transform: transform(), lease: lease())
                XCTFail(code)
            } catch { XCTAssertEqual((error as? DomainError)?.code, code) }
            XCTAssertTrue(driver.events.isEmpty, code)
        }
        let ambiguous = FakeInputDriver(); ambiguous.focusError = DomainError("focus_failed", "ambiguous")
        do {
            _ = try await DesktopInputController(driver: ambiguous).execute(.pressKey, args: .init(contextId: "x", key: "enter"),
                target: target, transform: transform(), lease: lease()); XCTFail()
        } catch { XCTAssertEqual((error as? DomainError)?.code, "focus_failed") }
        XCTAssertTrue(ambiguous.events.isEmpty)
    }
    func testStaleResizedInvalidAndOccludedPointsDoNotPost() async throws {
        for kind in 0..<5 {
            let driver = FakeInputDriver()
            if kind == 0 { driver.frame.width += 1 }
            if kind == 1 { driver.covered = true }
            if kind == 2 { driver.allocationFails = true }
            let args = InputArguments(contextId: "x", x: kind == 3 ? 400 : 10, y: 20)
            do {
                _ = try await DesktopInputController(driver: driver).execute(.click, args: args, target: target,
                    transform: kind == 4 ? nil : transform(), lease: lease()); XCTFail("\(kind)")
            } catch { }
            XCTAssertTrue(driver.events.isEmpty, "\(kind)")
        }
        let driver = FakeInputDriver()
        do {
            _ = try await DesktopInputController(driver: driver).execute(.click, args: .init(contextId: "x", x: 20, y: 20),
                target: target, transform: transform(), coordinatesFresh: false, lease: lease()); XCTFail()
        } catch { XCTAssertEqual((error as? DomainError)?.code, "capture_stale") }
        XCTAssertTrue(driver.events.isEmpty)
    }
    func testRecognizedDeleteControlPostsZeroEventsButScrollingStillWorks() async throws {
        let driver = FakeInputDriver(); driver.destructivePoint = true
        do {
            _ = try await DesktopInputController(driver: driver).execute(.click, args: .init(contextId: "x", x: 20, y: 20),
                target: target, transform: transform(), lease: lease()); XCTFail()
        } catch { XCTAssertEqual((error as? DomainError)?.code, "file_deletion_blocked") }
        XCTAssertTrue(driver.events.isEmpty)
        let scroll = try await DesktopInputController(driver: driver).execute(.scroll, args: .init(contextId: "x", deltaY: -1),
            target: target, transform: transform(), lease: lease())
        XCTAssertEqual(scroll.postedEvents, 2)
    }
    func testMovementRebasesPixelsExactlyAndReleaseIsBalanced() async throws {
        let driver = FakeInputDriver(); driver.frame.x += 70; driver.frame.y -= 25
        let result = try await DesktopInputController(driver: driver).execute(.click, args: .init(contextId: "x", x: 20, y: 30),
            target: target, transform: transform(), lease: lease())
        XCTAssertEqual(result.postedEvents, 3)
        guard case .down(let point) = driver.events[1], case .up(let release) = driver.events[2] else { return XCTFail() }
        XCTAssertEqual(point, Point(x: -690, y: 135)); XCTAssertEqual(release, point)
    }
    func testRevokedLeaseAndDisabledControlDoNotPost() async throws {
        for disabled in [false, true] {
            let driver = FakeInputDriver(); let token = lease()
            if !disabled { token.revoke() }
            do {
                _ = try await DesktopInputController(driver: driver, enabled: { !disabled }).execute(.typeText,
                    args: .init(contextId: "x", text: "not sent"), target: target, transform: transform(), lease: token); XCTFail()
            } catch { }
            XCTAssertTrue(driver.events.isEmpty)
        }
    }
    func testMidTypingSecurityChangeStopsWithoutRetryAndBalancesPair() async throws {
        let driver = FakeInputDriver()
        driver.onPost = { if driver.events.count == 2 { driver.securityError = DomainError("secure_input", "became secure") } }
        do {
            _ = try await DesktopInputController(driver: driver).execute(.typeText,
                args: .init(contextId: "x", text: String(repeating: "x", count: 50)), target: target, transform: transform(), lease: lease()); XCTFail()
        } catch { XCTAssertEqual((error as? DomainError)?.code, "input_failed") }
        XCTAssertEqual(driver.events.count, 2)
        guard case .unicode(_, true) = driver.events[0], case .unicode(_, false) = driver.events[1] else { return XCTFail() }
    }
    func testPartialChordReleasesOnlyPressedModifiers() async throws {
        let driver = FakeInputDriver(); var enabled = true
        driver.onPost = { enabled = false }
        do {
            _ = try await DesktopInputController(driver: driver, enabled: { enabled }).execute(.keyChord,
                args: .init(contextId: "x", key: "s", modifiers: ["cmd", "ctrl"]), target: target, transform: transform(), lease: lease()); XCTFail()
        } catch { XCTAssertEqual((error as? DomainError)?.code, "input_failed") }
        XCTAssertEqual(driver.events.count, 2)
        guard case .key(59, true, _) = driver.events[0], case .key(59, false, let flags) = driver.events[1] else { return XCTFail() }
        XCTAssertTrue(flags.isEmpty)
    }
    func testKeyboardLayoutLookupFromWorkerDoesNotPostOrCrash() async throws {
        let code = try await Task.detached { try await KeyboardMapping.code("a", command: true) }.value
        XCTAssertLessThan(code, 128)
        let space = try await Task.detached { try await KeyboardMapping.code("space", command: false) }.value
        XCTAssertEqual(space, 49)
        do {
            _ = try await KeyboardMapping.code("not-a-key", command: false)
            XCTFail("Unsupported key was accepted")
        } catch { XCTAssertEqual((error as? DomainError)?.code, "invalid_arguments") }
    }
    func testOnlyVerifiedSystemCursorIsExcludedFromOcclusion() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"
        XCTAssertTrue(InputPolicy.isSystemCursor(level: 99, cursorLevel: 99, uid: 88, windowServerUID: 88, executable: path))
        XCTAssertFalse(InputPolicy.isSystemCursor(level: 99, cursorLevel: 99, uid: 501, windowServerUID: 88, executable: path))
        XCTAssertFalse(InputPolicy.isSystemCursor(level: 99, cursorLevel: 99, uid: 88, windowServerUID: 88, executable: "/tmp/WindowServer"))
        XCTAssertFalse(InputPolicy.isSystemCursor(level: 25, cursorLevel: 99, uid: 88, windowServerUID: 88, executable: path))
        XCTAssertFalse(InputPolicy.isSystemCursor(level: 99, cursorLevel: 99, uid: nil, windowServerUID: 88, executable: path))
        XCTAssertFalse(InputPolicy.isSystemCursor(level: 99, cursorLevel: 99, uid: 88, windowServerUID: nil, executable: path))
    }
    func testValidationAndSystemEscapeShortcuts() {
        for (key, modifiers) in [("tab", ["cmd"]), ("space", ["cmd"]), ("escape", ["cmd", "alt"]), ("arrowleft", ["ctrl"])] {
            XCTAssertThrowsError(try InputAction.keyChord.validate(.init(contextId: "x", key: key, modifiers: modifiers)))
        }
        XCTAssertNoThrow(try InputAction.keyChord.validate(.init(contextId: "x", key: "s", modifiers: ["cmd"])))
        XCTAssertNoThrow(try InputAction.pressKey.validate(.init(contextId: "x", key: "space")))
        XCTAssertThrowsError(try InputAction.scroll.validate(.init(contextId: "x", x: 4, deltaY: -1)))
        XCTAssertThrowsError(try InputAction.typeText.validate(.init(contextId: "x", text: "")))
        XCTAssertNoThrow(try InputPolicy.validateIdentity(bundleID: "com.apple.Terminal", uid: 501, currentUID: 501, layer: 0))
        XCTAssertThrowsError(try InputPolicy.validateIdentity(bundleID: "fixture", uid: 0, currentUID: 501, layer: 0))
        XCTAssertThrowsError(try InputPolicy.validateIdentity(bundleID: nil, uid: 501, currentUID: 501, layer: 0))
        XCTAssertThrowsError(try InputPolicy.validateIdentity(bundleID: "fixture", uid: 502, currentUID: 501, layer: 0))
    }
    func testTextFidelityNewlinesPacingAndNoClipboard() async throws {
        let text = "First ü😀\r\n\r\n日本語\rLast\n" // CRLF is one break; blank lines survive.
        let strokes = TextInput.strokes(text)
        XCTAssertEqual(strokes.filter { $0 == .enter }.count, 4)
        let driver = FakeInputDriver()
        _ = try await DesktopInputController(driver: driver, typeInterval: 0).execute(.typeText,
            args: .init(contextId: "x", text: text), target: target, transform: transform(), lease: lease())
        var delivered = ""
        for (index, event) in driver.events.enumerated() where index % 2 == 0 {
            switch event {
            case .unicode(let units, true):
                delivered += String(decoding: units, as: UTF16.self)
                guard case .unicode(let release, false) = driver.events[index + 1] else { return XCTFail() }
                XCTAssertEqual(units, release)
            case .key(36, true, _):
                delivered += "\n"
                guard case .key(36, false, _) = driver.events[index + 1] else { return XCTFail() }
            default: XCTFail("Unexpected text event")
            }
        }
        XCTAssertEqual(delivered, "First ü😀\n\n日本語\nLast\n")
        let paced = FakeInputDriver(), start = Date()
        _ = try await DesktopInputController(driver: paced, typeInterval: 20).execute(.typeText,
            args: .init(contextId: "x", text: "abc"), target: target, transform: transform(), lease: lease())
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.035)
        XCTAssertEqual(TextInput.intervalMilliseconds([:]), 20)
        XCTAssertEqual(TextInput.intervalMilliseconds(["PI_OS_TYPE_INTERVAL_MS": "0"]), 0)
        XCTAssertEqual(TextInput.intervalMilliseconds(["PI_OS_TYPE_INTERVAL_MS": "nan"]), 20)
        let tooLong = FakeInputDriver()
        do {
            _ = try await DesktopInputController(driver: tooLong, typeInterval: 20).execute(.typeText,
                args: .init(contextId: "x", text: String(repeating: "x", count: 1001)), target: target, transform: transform(), lease: lease())
            XCTFail("Oversized paced call was accepted")
        } catch { XCTAssertEqual((error as? DomainError)?.code, "invalid_arguments") }
        XCTAssertTrue(tooLong.events.isEmpty); XCTAssertEqual(tooLong.focused, 0)
    }
    func testUnicodeChunkBoundariesAndBudget() throws {
        let text = String(repeating: "a", count: 19) + "😀日本語👨‍👩‍👧‍👦" + String(repeating: "b", count: 30)
        let chunks = InputPolicy.unicodeChunks(text)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 20 })
        XCTAssertEqual(String(decoding: chunks.flatMap { $0 }, as: UTF16.self), text)
        for chunk in chunks {
            XCTAssertFalse((0xD800...0xDBFF).contains(chunk.last!))
            XCTAssertFalse((0xDC00...0xDFFF).contains(chunk.first!))
        }
        var budget = InputBudget()
        for _ in 0..<200 { try budget.reserve(.focus, arguments: .init(contextId: "x")) }
        XCTAssertThrowsError(try budget.reserve(.focus, arguments: .init(contextId: "x")))
    }
    func testImageSizingPreventsDownstreamResize() {
        for size in [(800.0, 600.0), (1728, 1117), (3840, 2160), (2000, 2000), (800, 1600)] {
            let frame = Rect(x: -900, y: 100, width: size.0, height: size.1)
            let pixels = CaptureSizing.pixels(for: frame)
            XCTAssertLessThanOrEqual(max(pixels.width, pixels.height), 1280)
            XCTAssertLessThanOrEqual(pixels.width * pixels.height, 1_000_000)
            XCTAssertLessThanOrEqual(Double(pixels.width), frame.width)
            XCTAssertNoThrow(try CaptureTransform(frame: frame, imageWidth: pixels.width, imageHeight: pixels.height))
        }
    }
    func testCatalogAdvertisesInputOnlyWhenExplicitlyAvailable() throws {
        func names(_ response: HTTPResponse) throws -> [[String: Any]] {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
            return try XCTUnwrap(json["tools"] as? [[String: Any]])
        }
        XCTAssertEqual(try names(HostRoutes.catalog()).count, 3)
        let full = try names(HostRoutes.catalog(includeInput: true))
        XCTAssertEqual(full.count, 9)
        let click = try XCTUnwrap(full.first { $0["name"] as? String == "input.click" })
        let schema = try XCTUnwrap(click["inputSchema"] as? [String: Any])
        XCTAssertTrue((schema["required"] as? [String])?.contains("screenshotId") == true)
    }
    func testDisabledHostRejectsRawInputRoute() async throws {
        let host = DesktopService(captures: FileManager.default.temporaryDirectory, token: "secret")
        var parser = HTTPParser()
        let body = "{\"arguments\":{\"contextId\":\"x\",\"text\":\"not sent\"}}"
        let request = try XCTUnwrap(parser.append(Data("POST /tools/input.typeText HTTP/1.1\r\nHost: localhost\r\nX-Harness-Token: secret\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)))
        let response = await host.handle(request)
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains("control_disabled"))
    }
    func testGateCancellationDoesNotStealAnotherPermit() async throws {
        let gate = OperationGate()
        try await gate.acquire()
        let waiting = Task { try await gate.acquire(); await gate.release() }
        waiting.cancel()
        do { try await waiting.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        await gate.release()
        try await gate.acquire(); await gate.release()
    }
}
