import XCTest
@testable import ShellCore

final class HotkeyTests: XCTestCase {
    func testDefaultAndAliasesNormalize() throws {
        XCTAssertEqual(try Hotkey.parse(" control + OPTION + Space "), .defaultBinding)
        XCTAssertEqual(try Hotkey.parse("shift+cmd+ctrl+f9").description, "Ctrl+Shift+Cmd+F9")
        XCTAssertEqual(try Hotkey.parse("Command+Opt+F12").description, "Alt+Cmd+F12")
    }
    func testFunctionKeyRangeAndRoundTrips() throws {
        for n in 1...12 {
            let hotkey = try Hotkey.parse("Ctrl+Shift+F\(n)")
            XCTAssertEqual(hotkey.key, .function(n))
            XCTAssertEqual(try Hotkey.parse(hotkey.description), hotkey)
        }
    }
    func testRejectsUnsupportedAmbiguousAndMalformedBindings() {
        for text in ["", "Space", "F9", "Ctrl++Space", "+Ctrl+Space", "Ctrl+Space+",
                     "Ctrl+Ctrl+Space", "Alt+Option+F1", "Cmd+Command+F2", "Hyper+F1",
                     "Ctrl+A", "Ctrl+1", "Ctrl+F0", "Ctrl+F13", "Ctrl+F01",
                     "Ctrl+Enter", "Ctrl+F1+F2", "Ctrl+💡", "Ctrl+Shift"] {
            XCTAssertThrowsError(try Hotkey.parse(text), text)
        }
    }
    func testShiftOnlyIsAnExplicitModifiedBinding() throws {
        XCTAssertEqual(try Hotkey.parse("Shift+F8").modifiers, [.shift])
    }
    func testFailedReplacementPreservesPreviousRegistration() throws {
        enum Failure: Error { case conflict }
        var binding = HotkeyBinding<Int>()
        var released: [Int] = []
        try binding.replace(with: Hotkey.parse("Ctrl+F1"), register: { _ in 1 }, unregister: { released.append($0) })
        XCTAssertThrowsError(try binding.replace(with: Hotkey.parse("Ctrl+F2"), register: { _ in
            throw Failure.conflict
        }, unregister: { released.append($0) }))
        XCTAssertEqual(binding.hotkey?.description, "Ctrl+F1")
        XCTAssertTrue(released.isEmpty)
        binding.clear { released.append($0) }
        XCTAssertEqual(released, [1])
    }
    func testUnchangedBindingDoesNotRegisterTwiceAndReplacementReleasesOld() throws {
        var binding = HotkeyBinding<Int>()
        var events: [String] = []
        let first = try Hotkey.parse("Ctrl+F1")
        binding.replace(with: first, register: { _ in events.append("register1"); return 1 },
                        unregister: { events.append("release\($0)") })
        XCTAssertFalse(binding.replace(with: first, register: { _ in XCTFail("duplicate"); return 9 },
                                       unregister: { _ in XCTFail("duplicate release") }))
        try binding.replace(with: Hotkey.parse("Ctrl+F2"), register: { _ in events.append("register2"); return 2 },
                            unregister: { events.append("release\($0)") })
        XCTAssertEqual(events, ["register1", "register2", "release1"])
        binding.clear { events.append("release\($0)") }
        binding.clear { _ in XCTFail("double release") }
        XCTAssertNil(binding.hotkey)
        XCTAssertEqual(events.last, "release2")
    }
    func testInitialFailureLeavesNoBinding() {
        enum Failure: Error { case unavailable }
        var binding = HotkeyBinding<Int>()
        XCTAssertThrowsError(try binding.replace(with: .defaultBinding, register: { _ in throw Failure.unavailable },
                                                unregister: { _ in XCTFail("nothing registered") }))
        XCTAssertNil(binding.hotkey)
    }
}
