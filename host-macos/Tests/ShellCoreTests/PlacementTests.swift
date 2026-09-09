import Foundation
import CoreGraphics
import XCTest
@testable import ShellCore

final class PlacementTests: XCTestCase {
    private let left = ScreenArea(id: 1, frame: CGRect(x: -1440, y: -200, width: 1440, height: 900),
                                 visibleFrame: CGRect(x: -1400, y: -180, width: 1400, height: 850))
    private let right = ScreenArea(id: 2, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                  visibleFrame: CGRect(x: 0, y: 60, width: 1920, height: 995))

    func testScreenSelectionSupportsNegativeOrigins() {
        XCTAssertEqual(Placement.screen(at: CGPoint(x: -500, y: -100), among: [right, left]), left)
    }
    func testSharedBoundaryBelongsToScreenBeginningThere() {
        XCTAssertEqual(Placement.screen(at: CGPoint(x: 0, y: 100), among: [left, right]), right)
    }
    func testGapChoosesNearestAndTiesKeepOrder() {
        let other = ScreenArea(id: 3, frame: CGRect(x: 2100, y: 0, width: 500, height: 500),
                               visibleFrame: CGRect(x: 2100, y: 0, width: 500, height: 500))
        XCTAssertEqual(Placement.screen(at: CGPoint(x: 2090, y: 100), among: [right, other]), other)
        XCTAssertEqual(Placement.screen(at: CGPoint(x: 2010, y: 100), among: [right, other]), right)
    }
    func testEmptyAndInvalidGeometryFailClosed() {
        XCTAssertNil(Placement.screen(at: .zero, among: []))
        XCTAssertNil(Placement.screen(at: CGPoint(x: CGFloat.nan, y: 0), among: [right]))
        let invalid = ScreenArea(id: 3, frame: .zero, visibleFrame: right.visibleFrame)
        XCTAssertNil(Placement.screen(at: .zero, among: [invalid]))
        XCTAssertNil(Placement.frame(size: CGSize(width: 100, height: 100), on: invalid))
        XCTAssertNil(Placement.frame(size: CGSize(width: CGFloat.infinity, height: 100), on: right))
        XCTAssertNil(Placement.frame(size: CGSize(width: -1, height: 100), on: right))
        XCTAssertNil(Placement.frame(size: CGSize(width: 100, height: 100), on: right, inset: .nan))
    }
    func testTopCenterClampedInsideMenuBarAndDockExclusions() throws {
        let frame = try XCTUnwrap(Placement.frame(size: CGSize(width: 540, height: 440), on: left))
        XCTAssertEqual(frame, CGRect(x: -970, y: 206, width: 540, height: 440))
        XCTAssertTrue(left.visibleFrame.contains(frame))
    }
    func testOversizedPanelShrinksInsteadOfOverflowing() throws {
        let frame = try XCTUnwrap(Placement.frame(size: CGSize(width: 4000, height: 4000), on: right))
        XCTAssertEqual(frame.size, CGSize(width: 1872, height: 947))
        XCTAssertTrue(right.visibleFrame.contains(frame))
    }
    func testFractionalPointsAreNotScaledLikeScreenshotPixels() throws {
        let screen = ScreenArea(id: 4, frame: CGRect(x: -100.5, y: 20.25, width: 500.5, height: 400.5),
                                visibleFrame: CGRect(x: -100.5, y: 20.25, width: 500.5, height: 400.5))
        let frame = try XCTUnwrap(Placement.frame(size: CGSize(width: 200.5, height: 100.25), on: screen, inset: 12.5))
        XCTAssertEqual(frame.origin, CGPoint(x: 49.5, y: 308))
        XCTAssertEqual(frame.size, CGSize(width: 200.5, height: 100.25))
    }
    func testTinyDisplayAndExcessiveInsetRemainUsable() throws {
        let tiny = ScreenArea(id: 5, frame: CGRect(x: 0, y: 0, width: 20, height: 10),
                              visibleFrame: CGRect(x: 0, y: 0, width: 20, height: 10))
        let frame = try XCTUnwrap(Placement.frame(size: CGSize(width: 500, height: 500), on: tiny, inset: 500))
        XCTAssertTrue(tiny.frame.contains(frame))
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
    }
    func testRemovedDisplayFallsBackToRemainingScreen() {
        XCTAssertEqual(Placement.screen(at: CGPoint(x: -500, y: -100), among: [right]), right)
    }
    func testVisibleFrameIsIntersectedWithScreenAndDisjointAreaRejected() throws {
        let partial = ScreenArea(id: 6, frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                 visibleFrame: CGRect(x: 50, y: 50, width: 200, height: 200))
        let frame = try XCTUnwrap(Placement.frame(size: CGSize(width: 80, height: 80), on: partial, inset: 0))
        XCTAssertEqual(frame, CGRect(x: 50, y: 50, width: 50, height: 50))
        let disjoint = ScreenArea(id: 7, frame: partial.frame,
                                  visibleFrame: CGRect(x: 200, y: 0, width: 100, height: 100))
        XCTAssertNil(Placement.frame(size: CGSize(width: 10, height: 10), on: disjoint))
        XCTAssertNil(Placement.screen(at: .zero, among: [disjoint]))
    }
}
