import XCTest
@testable import PiOSCore
@testable import PiOSMac

private final class FakeFinderTree: FinderTreeReader {
    typealias Node = String
    var exhausted = false
    var descendants = ["app": ["desktop", "window"], "desktop": ["icon"]]
    var parents = ["desktop": "app", "icon": "desktop", "sidebar": "window"]
    var roles = ["app": "AXApplication", "desktop": "AXScrollArea", "window": "AXWindow", "icon": "AXImage", "sidebar": "AXOutline"]
    var frames = ["desktop": Rect(x: -1920, y: 0, width: 1920, height: 1080)]
    var foreign: Set<String> = []
    var selected: FinderSelectionRead<String> = .available(count: 1, nodes: ["icon"])
    func children(_ node: String) -> [String]? { descendants[node] }
    func parent(_ node: String) -> String? { parents[node] }
    func role(_ node: String) -> String? { roles[node] }
    func frame(_ node: String) -> Rect? { frames[node] }
    func owner(_ node: String) -> Int32? { foreign.contains(node) ? 99 : 42 }
    func selection(_ node: String, limit: Int) -> FinderSelectionRead<String> { selected }
    func summary(_ node: String) -> ElementSummary? { .init(name: node, controlType: roles[node]) }
}

final class FinderTests: XCTestCase {
    let frame = Rect(x: -1920, y: 0, width: 1920, height: 1080)
    func testMatchesOnlyUniqueDirectDesktopContainer() {
        let tree = FakeFinderTree()
        XCTAssertEqual(FinderContextPolicy.desktopContainer(reader: tree, application: "app", pid: 42, frame: frame), "desktop")
        tree.roles["window"] = "AXScrollArea"; tree.frames["window"] = frame
        XCTAssertNil(FinderContextPolicy.desktopContainer(reader: tree, application: "app", pid: 42, frame: frame))
        tree.roles["window"] = "AXWindow"
        tree.foreign.insert("desktop")
        XCTAssertNil(FinderContextPolicy.desktopContainer(reader: tree, application: "app", pid: 42, frame: frame))
    }
    func testDesktopWorkAreaMustBeExplicitAndContainedNotGuessed() {
        let tree = FakeFinderTree()
        let workArea = Rect(x: -1920, y: 25, width: 1920, height: 1000)
        tree.frames["desktop"] = workArea
        XCTAssertNil(FinderContextPolicy.desktopContainer(reader: tree, application: "app", pid: 42, frame: frame))
        XCTAssertEqual(FinderContextPolicy.desktopContainer(reader: tree, application: "app", pid: 42, frame: frame, workArea: workArea), "desktop")
        let outside = Rect(x: -2000, y: 25, width: 1920, height: 1000)
        tree.frames["desktop"] = outside
        XCTAssertNil(FinderContextPolicy.desktopContainer(reader: tree, application: "app", pid: 42, frame: frame, workArea: outside))
    }
    func testObservedSharedDesktopContainerDoesNotWidenKeyboardAuthority() {
        let tree = FakeFinderTree()
        let other = Rect(x: 0, y: 0, width: 1920, height: 1080)
        let union = FinderContextPolicy.union([frame, other])!
        tree.frames["desktop"] = union
        XCTAssertNil(FinderContextPolicy.desktopContainer(reader: tree, application: "app", pid: 42, frame: frame))
        XCTAssertEqual(FinderContextPolicy.desktopContainer(reader: tree, application: "app", pid: 42, frame: frame, desktopUnion: union), "desktop")
        tree.frames["icon"] = Rect(x: -1000, y: 100, width: 80, height: 80)
        XCTAssertTrue(FinderContextPolicy.keyboardSelectionIsWithin(reader: tree, container: "desktop", pid: 42, frame: frame))
        tree.frames["icon"] = Rect(x: 100, y: 100, width: 80, height: 80)
        XCTAssertFalse(FinderContextPolicy.keyboardSelectionIsWithin(reader: tree, container: "desktop", pid: 42, frame: frame))
        tree.selected = .available(count: 0, nodes: [])
        XCTAssertFalse(FinderContextPolicy.keyboardSelectionIsWithin(reader: tree, container: "desktop", pid: 42, frame: frame))
        tree.frames["desktop"] = frame
        XCTAssertTrue(FinderContextPolicy.keyboardSelectionIsWithin(reader: tree, container: "desktop", pid: 42, frame: frame))
    }
    func testCannotMistakeWindowSidebarOrFocusedItemForDesktopSelection() {
        let tree = FakeFinderTree()
        tree.selected = .available(count: 1, nodes: ["sidebar"])
        XCTAssertNil(FinderContextPolicy.selected(reader: tree, container: "desktop", pid: 42))
        tree.selected = .unavailable
        XCTAssertNil(FinderContextPolicy.selected(reader: tree, container: "desktop", pid: 42))
        XCTAssertFalse(FinderContextPolicy.isDescendant(reader: tree, node: "sidebar", of: "desktop", pid: 42))
    }
    func testEmptyUnavailableAndTruncatedAreDifferent() throws {
        let tree = FakeFinderTree()
        tree.selected = .available(count: 0, nodes: [])
        let empty = try XCTUnwrap(FinderContextPolicy.selected(reader: tree, container: "desktop", pid: 42))
        XCTAssertTrue(empty.items.isEmpty); XCTAssertEqual(empty.totalCount, 0); XCTAssertFalse(empty.truncated)
        tree.selected = .available(count: 100, nodes: ["icon"])
        let truncated = try XCTUnwrap(FinderContextPolicy.selected(reader: tree, container: "desktop", pid: 42, limit: 1))
        XCTAssertEqual(truncated.items.count, 1); XCTAssertEqual(truncated.totalCount, 100); XCTAssertTrue(truncated.truncated)
        tree.exhausted = true
        XCTAssertNil(FinderContextPolicy.selected(reader: tree, container: "desktop", pid: 42, limit: 1))
    }
    func testCyclesForeignItemsAndIncompleteReadsFailClosed() {
        let tree = FakeFinderTree()
        tree.parents["icon"] = "icon"
        XCTAssertNil(FinderContextPolicy.selected(reader: tree, container: "desktop", pid: 42))
        tree.parents["icon"] = "desktop"; tree.foreign.insert("icon")
        XCTAssertNil(FinderContextPolicy.selected(reader: tree, container: "desktop", pid: 42))
        tree.foreign.removeAll(); tree.selected = .available(count: 2, nodes: ["icon"])
        XCTAssertNil(FinderContextPolicy.selected(reader: tree, container: "desktop", pid: 42))
    }
    func testDesktopInputLayerExceptionIsFinderOnly() {
        XCTAssertNoThrow(try InputPolicy.validateIdentity(bundleID: "com.apple.finder", uid: 501, currentUID: 501,
            layer: -10, finderDesktop: true, desktopLayer: -10))
        for bundle in ["com.apple.Terminal", "other.app", ""] {
            XCTAssertThrowsError(try InputPolicy.validateIdentity(bundleID: bundle, uid: 501, currentUID: 501,
                layer: -10, finderDesktop: true, desktopLayer: -10))
        }
        XCTAssertThrowsError(try InputPolicy.validateIdentity(bundleID: "com.apple.finder", uid: 501, currentUID: 501,
            layer: 0, finderDesktop: true, desktopLayer: -10))
        XCTAssertThrowsError(try InputPolicy.validateIdentity(bundleID: "com.apple.finder", uid: 0, currentUID: 501,
            layer: -10, finderDesktop: true, desktopLayer: -10))
    }
    func testDesktopSelectionCodablePreservesCheckedEmptyAndUnavailable() throws {
        var target = WindowContext(windowID: 7, pid: 42, name: "Finder", title: "Desktop", bounds: frame)
        target.surface = FinderContextPolicy.desktopSurface
        var snapshot = Snapshot(cursor: Point(x: -100, y: 100), target: target, underCursor: target, monitors: [])
        let unknown = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        XCTAssertNil(unknown["selectedDesktopItems"])
        snapshot.selectedDesktopItems = []; snapshot.selectedDesktopItemCount = 0; snapshot.selectedDesktopItemsTruncated = false
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(Snapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
        let known = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((known["selectedDesktopItems"] as? [Any])?.count, 0)
    }
}
