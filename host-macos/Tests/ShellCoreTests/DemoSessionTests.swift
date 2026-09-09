import XCTest
@testable import ShellCore

final class DemoSessionTests: XCTestCase {
    func testPromptToDemonstrationToReader() throws {
        var session = DemoSession()
        XCTAssertEqual(session.phase, .closed)
        session.openPrompt()
        let generation = try XCTUnwrap(session.submit("synthetic sample"))
        XCTAssertEqual(session.phase, .demonstrating(generation))
        XCTAssertTrue(session.complete(generation: generation))
        XCTAssertEqual(session.phase, .reader(.demonstration))
        XCTAssertFalse(session.complete(generation: generation))
    }
    func testEmptyOversizedAndDoubleSubmissionsRejected() throws {
        var session = DemoSession()
        XCTAssertNil(session.submit("outside prompt"))
        session.openPrompt()
        XCTAssertNil(session.submit(" \r\n\t"))
        XCTAssertNotNil(session.validationMessage)
        XCTAssertNil(session.submit(String(repeating: "a", count: 2001)))
        let generation = try XCTUnwrap(session.submit(String(repeating: "💡", count: 2000)))
        XCTAssertNil(session.validationMessage)
        XCTAssertNil(session.submit("duplicate"))
        XCTAssertEqual(session.phase, .demonstrating(generation))
    }
    func testCancellationRejectsLateCompletion() throws {
        var session = DemoSession()
        session.openPrompt()
        let generation = try XCTUnwrap(session.submit("sample"))
        session.cancel()
        XCTAssertEqual(session.phase, .reader(.canceled))
        XCTAssertFalse(session.complete(generation: generation))
        session.cancel()
        XCTAssertEqual(session.phase, .closed)
    }
    func testPromptCancelAndCloseAreIdempotent() {
        var session = DemoSession()
        session.openPrompt()
        session.cancel()
        XCTAssertEqual(session.phase, .closed)
        session.close()
        session.close()
        XCTAssertEqual(session.phase, .closed)
    }
    func testReplacementAndQuitRejectStaleCallbacks() throws {
        var session = DemoSession()
        session.openPrompt()
        let old = try XCTUnwrap(session.submit("first"))
        session.close()
        session.openPrompt()
        let new = try XCTUnwrap(session.submit("second"))
        XCTAssertNotEqual(old, new)
        XCTAssertFalse(session.complete(generation: old))
        XCTAssertEqual(session.phase, .demonstrating(new))
        session.close()
        XCTAssertFalse(session.complete(generation: new))
    }
    func testUnsupportedReplacesDemoWithoutPretendingToBeAgentFailure() throws {
        var session = DemoSession()
        session.openPrompt()
        let generation = try XCTUnwrap(session.submit("sample"))
        session.showUnsupported()
        XCTAssertEqual(session.phase, .reader(.unsupported))
        XCTAssertFalse(session.complete(generation: generation))
        XCTAssertNil(session.submit("follow-up is not implemented"))
        XCTAssertTrue(DemoSession.text(for: .unsupported).contains("not a complete or usable agent Mac port"))
    }
    func testPromptTextIsNotRetainedInStateOrResponse() {
        var first = DemoSession()
        var second = DemoSession()
        first.openPrompt()
        second.openPrompt()
        _ = first.submit("synthetic one")
        _ = second.submit("different synthetic two")
        XCTAssertEqual(first, second)
        XCTAssertFalse(DemoSession.text(for: .demonstration).contains("synthetic one"))
    }
}
