import XCTest
import Darwin
@testable import PiOSCore
@testable import PiOSMac

final class LifecycleTests: XCTestCase {
    private func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return UInt16(bigEndian: address.sin_port)
    }
    @MainActor func testLazyOwnedGroupWarmReuseTTLAndRestart() async throws {
        let paths = ProcessInfo.processInfo.environment["PATH", default: ""].split(separator: ":").map { String($0) + "/node" }
        let node = try XCTUnwrap(paths.first { FileManager.default.isExecutableFile(atPath: $0) }, "Node is required for the Mac lifecycle gate")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-os-lifecycle-" + UUID().uuidString)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let entry = root.appendingPathComponent("node-harness/dist/index.js").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry), "Build node-harness before running lifecycle tests")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let wrapper = directory.appendingPathComponent("offline-harness.mjs")
        let guardURL = root.appendingPathComponent("node-harness/test/no-live-models.mjs").absoluteString
        let entryURL = URL(fileURLWithPath: entry).absoluteString
        try "await import(\(String(data: try JSONEncoder().encode(guardURL), encoding: .utf8)!)); await import(\(String(data: try JSONEncoder().encode(entryURL), encoding: .utf8)!));"
            .write(to: wrapper, atomically: true, encoding: .utf8)
        let config = try MacConfiguration(env: ["PI_OS_SUPPORT_DIR": directory.path, "PI_OS_NODE_PATH": node,
                                                "PI_OS_NODE_ENTRY": wrapper.path, "PI_OS_NODE_WARM_TTL_SECONDS": "0.03",
                                                "PI_OS_NODE_PORT": String(try freePort())])
        let client = HarnessClient(config: config)
        defer { client.stop(); try? FileManager.default.removeItem(at: directory) }
        XCTAssertNil(client.ownedPID, "No child at ordinary idle")
        let start = Date()
        try await client.warm()
        print("[measurement] native-supervised-harness-ready ms=\(Date().timeIntervalSince(start) * 1000)")
        let pid = try XCTUnwrap(client.ownedPID)
        XCTAssertEqual(getpgid(pid), pid, "Child must own a dedicated group")
        try await client.warm()
        XCTAssertEqual(client.ownedPID, pid, "Warm child is reused")
        let taskReservation = client.reserve(), settingsReservation = client.reserve()
        client.release(settingsReservation)
        client.retainWarm()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(client.ownedPID, pid, "Closing Settings must not expire a child reserved by an active task")
        client.release(taskReservation)
        for _ in 0..<100 where client.ownedPID != nil { try await Task.sleep(nanoseconds: 30_000_000) }
        XCTAssertNil(client.ownedPID, "TTL reaps Node without an idle poller")
        try await client.warm()
        XCTAssertNotEqual(client.ownedPID, pid)
        client.stop()
        // Hotkey pressed while the previous process is still being reaped.
        try await client.warm()
        let last = try XCTUnwrap(client.ownedPID)
        let exited = expectation(description: "unexpected exit is surfaced")
        client.onUnexpectedExit = { exited.fulfill() }
        XCTAssertEqual(kill(last, SIGKILL), 0) // only this test's verified owned child
        await fulfillment(of: [exited], timeout: 3)
        XCTAssertNil(client.ownedPID)

        let brokenEntry = directory.appendingPathComponent("broken.mjs")
        try "process.exit(2);".write(to: brokenEntry, atomically: true, encoding: .utf8)
        let broken = HarnessClient(config: try MacConfiguration(env: [
            "PI_OS_SUPPORT_DIR": directory.path, "PI_OS_NODE_PATH": node,
            "PI_OS_NODE_ENTRY": brokenEntry.path, "PI_OS_NODE_PORT": String(try freePort()),
        ]))
        defer { broken.stop() }
        do { try await broken.warm(); XCTFail("Broken child became ready") }
        catch { XCTAssertEqual((error as? DomainError)?.code, "harness_unreachable", "Startup failure must not masquerade as user cancellation") }
        XCTAssertNil(broken.ownedPID)
    }
    func testDeadlineTimeoutCancellationAndLateCallbacks() async throws {
        do {
            let _: Int = try await Deadline.call(seconds: 0.01) { _ in }
            XCTFail("Missing callback never timed out")
        } catch { XCTAssertEqual((error as? DomainError)?.code, "capture_failed") }
        let task = Task<Int, Error> {
            try await Deadline.call(seconds: 30) { done in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { done(.success(2)); done(.success(3)) }
            }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled callback succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        let value: Int = try await Deadline.call(seconds: 1) { $0(.success(42)) }
        XCTAssertEqual(value, 42)
    }
}
