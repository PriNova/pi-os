import XCTest
@testable import PiOSCore
@testable import PiOSMac

final class BrowserTests: XCTestCase {
    func testOnlyWebPagesWithoutEmbeddedCredentials() {
        for value in ["https://example.com/", "http://127.0.0.1:9999/test"] { XCTAssertTrue(BrowserPolicy.validURL(value)) }
        for value in ["file:///tmp/test", "javascript:alert(1)", "brave://settings", "https://user:secret@example.com", "data:text/html,test", "https://", String(repeating: "x", count: 9000)] {
            XCTAssertFalse(BrowserPolicy.validURL(value))
        }
    }
    func testBrowserMetadataIsAdditiveAndContainsNoEndpoint() throws {
        var snapshot = Snapshot(cursor: Point(x: 0, y: 0), target: nil, underCursor: nil, monitors: [])
        snapshot.browser = BrowserHint(pinned: false)
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(Snapshot.self, from: data)
        XCTAssertEqual(decoded.browser?.mode, "cdp")
        XCTAssertEqual(decoded.browser?.pinned, false)
        let text = String(data: data, encoding: .utf8)!
        XCTAssertFalse(text.contains("9222")); XCTAssertFalse(text.contains("initialURL"))
    }
    func testNativeBrowserBudgetSharesDesktopLimits() throws {
        func args(_ action: String, _ characters: Int = 0) throws -> BrowserArguments {
            try JSONDecoder().decode(BrowserArguments.self, from: Data("{\"contextId\":\"test\",\"action\":\"\(action)\",\"characters\":\(characters)}".utf8))
        }
        var budget = InputBudget()
        try BrowserPolicy.validateBudget(args("fill", 20_000), budget: &budget)
        XCTAssertEqual(budget.characters, 20_000)
        XCTAssertThrowsError(try BrowserPolicy.validateBudget(args("fill", 20_001), budget: &budget))
        XCTAssertThrowsError(try BrowserPolicy.validateBudget(args("click", 1), budget: &budget))
        XCTAssertThrowsError(try BrowserPolicy.validateBudget(args("evaluate"), budget: &budget))
        for _ in 0..<199 { try BrowserPolicy.validateBudget(args("click"), budget: &budget) }
        XCTAssertThrowsError(try BrowserPolicy.validateBudget(args("click"), budget: &budget))
    }
    func testNativeBrowserRoutesRequireHostTokenAndPinnedAuthority() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-os-browser-core-" + UUID().uuidString)
        let service = DesktopService(captures: directory, token: "private-token")
        let body = Data("{\"arguments\":{\"contextId\":\"unknown\"}}".utf8)
        let denied = await service.handle(HTTPRequest(method: "POST", path: "/tools/browser.connection", headers: [:], body: body))
        XCTAssertEqual(denied.status, 401)
        let disabled = await service.handle(HTTPRequest(method: "POST", path: "/tools/browser.connection", headers: ["x-harness-token": "private-token"], body: body))
        XCTAssertTrue(String(data: disabled.body, encoding: .utf8)!.contains("control_disabled"))
    }
}
