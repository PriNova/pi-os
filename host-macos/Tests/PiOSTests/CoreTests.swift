import XCTest
import Carbon
@testable import PiOSCore
@testable import PiOSMac

final class CoreTests: XCTestCase {
    func testHotkeyTable() throws {
        let codes: [UInt32] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, code) in codes.enumerated() { XCTAssertEqual(try HotkeyChord("Ctrl+F\(i + 1)").keyCode, code) }
        XCTAssertEqual(try HotkeyChord("Ctrl+Option+Cmd+Space").modifiers, UInt32(controlKey | optionKey | cmdKey))
        for raw in ["Space", "Ctrl+", "Ctrl+F13", "Ctrl+Control+A", "Hyper+A", "Ctrl++Space"] {
            XCTAssertThrowsError(try HotkeyChord(raw), raw)
        }
    }
    @MainActor func testExclusiveHotkeyRegistrationRejectsDuplicates() throws {
        let chord = try HotkeyChord("Ctrl+Option+Cmd+Shift+F12")
        let first = try GlobalHotkey(chord: chord, action: {})
        try withExtendedLifetime(first) {
            XCTAssertThrowsError(try GlobalHotkey(chord: chord, action: {})) {
                XCTAssertEqual(($0 as? DomainError)?.code, "hotkey_failed")
            }
        }
    }
    func testCoordinateBoundaryAndPlacement() {
        let target = Rect(x: -1920, y: -400, width: 1920, height: 1080)
        let flipped = Placement.appKit(target, primaryHeight: 1117)
        XCTAssertEqual(flipped, Rect(x: -1920, y: 437, width: 1920, height: 1080))
        XCTAssertEqual(Placement.appKit(flipped, primaryHeight: 1117), target)
        for work in [target, Rect(x: 0, y: 0, width: 1728, height: 1080), Rect(x: 1728, y: 1117, width: 1200, height: 800)] {
            let placed = Placement.panel(width: 620, height: 420, target: flipped, workArea: work)
            XCTAssertGreaterThanOrEqual(placed.x, work.x + 12)
            XCTAssertGreaterThanOrEqual(placed.y, work.y + 12)
            XCTAssertLessThanOrEqual(placed.x + placed.width, work.x + work.width - 12)
            XCTAssertLessThanOrEqual(placed.y + placed.height, work.y + work.height - 12)
        }
    }
    func testActualDimensionTransformsAndStaleRefusal() throws {
        for scale in [0.5, 1.0, 2.0] {
            for origin in [-1920.0, 0, 1728] {
                let frame = Rect(x: origin, y: -400, width: 800, height: 600)
                let transform = try CaptureTransform(frame: frame, imageWidth: Int(800 * scale), imageHeight: Int(600 * scale))
                let moved = Rect(x: origin + 30, y: 100, width: 800, height: 600)
                for i in 0..<100 {
                    let point = Point(x: Double(i) * 7 * scale, y: Double(i) * 5 * scale)
                    let screen = try transform.screenPoint(point, currentFrame: moved)
                    XCTAssertEqual(screen.x, moved.x + point.x / scale, accuracy: 0.000001)
                    XCTAssertEqual(screen.y, moved.y + point.y / scale, accuracy: 0.000001)
                }
                XCTAssertThrowsError(try transform.screenPoint(Point(x: 800 * scale, y: 0), currentFrame: moved))
                XCTAssertThrowsError(try transform.screenPoint(Point(x: .nan, y: 0), currentFrame: moved))
                XCTAssertThrowsError(try transform.screenPoint(Point(x: 1, y: 1), currentFrame: Rect(x: 0, y: 0, width: 801, height: 600))) {
                    XCTAssertEqual(($0 as? DomainError)?.code, "capture_stale")
                }
            }
        }
        XCTAssertThrowsError(try CaptureTransform(frame: Rect(x: 0, y: 0, width: 800, height: 600), imageWidth: 0, imageHeight: 600))
    }
    func testNullableSnapshotEncoding() throws {
        let s = Snapshot(cursor: Point(x: 0, y: 0), target: nil, underCursor: nil, monitors: [])
        let data = try JSONEncoder().encode(s)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(object["targetWindow"] is NSNull)
        XCTAssertTrue(object["foregroundWindow"] is NSNull)
        XCTAssertTrue(object["windowUnderCursor"] is NSNull)
        XCTAssertNil(object["screenshot"])
        XCTAssertEqual(try JSONDecoder().decode(Snapshot.self, from: data), s)
    }
    func testGoldenFixtures() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for name in ["macos-window", "macos-no-target"] {
            let data = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/\(name).json"))
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            let encoded = try JSONEncoder().encode(snapshot)
            let a = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
            let b = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
            XCTAssertEqual(a, b)
        }
    }
    func testAuthAndLock() throws {
        XCTAssertFalse(HostRoutes.authorized(nil, token: "token"))
        XCTAssertFalse(HostRoutes.authorized("other", token: "token"))
        XCTAssertFalse(HostRoutes.authorized("", token: ""))
        XCTAssertTrue(HostRoutes.authorized("token", token: "token"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var lock: InstanceLock? = try InstanceLock(directory: directory)
        XCTAssertNotNil(lock)
        XCTAssertThrowsError(try InstanceLock(directory: directory))
        lock = nil
        XCTAssertNoThrow(try InstanceLock(directory: directory))
    }
    func testGoneWindowDoesNotDegradeIntoAnotherTarget() async throws {
        let service = DesktopService(captures: FileManager.default.temporaryDirectory, token: "test")
        let target = WindowContext(windowID: 0, pid: -1, name: "gone", title: "", bounds: Rect(x: 0, y: 0, width: 800, height: 600))
        await service.insert(Snapshot(id: "gone", cursor: Point(x: 0, y: 0), target: target, underCursor: nil, monitors: []))
        do { _ = try await service.snapshot("gone"); XCTFail("Invalid identity survived") }
        catch { XCTAssertEqual((error as? DomainError)?.code, "target_gone") }
    }
    func testContextTTLAndCapacity() async throws {
        let directory = FileManager.default.temporaryDirectory
        let service = DesktopService(captures: directory, token: "test", ttl: 0.02, capacity: 1)
        let a = Snapshot(id: "a", cursor: Point(x: 0, y: 0), target: nil, underCursor: nil, monitors: [])
        let b = Snapshot(id: "b", cursor: Point(x: 0, y: 0), target: nil, underCursor: nil, monitors: [])
        await service.insert(a); await service.insert(b)
        do { _ = try await service.snapshot("a"); XCTFail("evicted context survived") }
        catch { XCTAssertEqual((error as? DomainError)?.code, "unknown_context") }
        do { _ = try await service.capture("b"); XCTFail("null target captured") }
        catch { XCTAssertEqual((error as? DomainError)?.code, "no_target") }
        try await Task.sleep(nanoseconds: 30_000_000)
        do { _ = try await service.snapshot("b"); XCTFail("expired context survived") }
        catch { XCTAssertEqual((error as? DomainError)?.code, "unknown_context") }
    }
}

final class HTTPTests: XCTestCase {
    func testFragmentedRequestEveryBoundary() throws {
        let bytes = Array("POST /tools/desktop.getContext HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\nX-Harness-Token: abc\r\n\r\n{}".utf8)
        for split in 1..<bytes.count {
            var parser = HTTPParser()
            XCTAssertNil(try parser.append(Data(bytes[..<split])))
            let result = try XCTUnwrap(parser.append(Data(bytes[split...])))
            XCTAssertEqual(result.path, "/tools/desktop.getContext")
            XCTAssertEqual(result.headers["x-harness-token"], "abc")
            XCTAssertEqual(result.body, Data("{}".utf8))
        }
    }
    func testStrictRequestFraming() {
        let invalid = [
            "POST / HTTP/1.1\r\nHost: x\r\n\r\n",
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: -1\r\n\r\n",
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: +1\r\n\r\n",
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n",
            "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n",
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1000001\r\n\r\n",
            "POST / HTTP/1.1\r\nHost: x\r\nContent-Length : 0\r\n\r\n",
            "GET / HTTP/1.1\r\n\r\n",
            "GET http://elsewhere/ HTTP/1.1\r\nHost: x\r\n\r\n",
            "GET / HTTP/1.1\r\nHost: x\r\n\r\nGET / HTTP/1.1\r\nHost: x\r\n\r\n",
            "GET / HTTP/1.1\r\nHost: x\r\nX: " + String(repeating: "x", count: 8192) + "\r\n\r\n",
        ]
        for raw in invalid { var p = HTTPParser(); XCTAssertThrowsError(try p.append(Data(raw.utf8))) }
    }
    func testHealthWithoutContentLengthAndConnectionClose() throws {
        var parser = HTTPParser()
        XCTAssertNotNil(try parser.append(Data("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)))
        let text = String(decoding: HTTPResponse.json(["ok": true]).wire, as: UTF8.self)
        XCTAssertTrue(text.contains("Connection: close\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 11\r\n"))
    }
}
