import AppKit
import XCTest
@testable import PiOSCore
@testable import PiOSMac

final class PresentationTests: XCTestCase {
    func testComposerReturnNewlineAndIMEPolicy() {
        XCTAssertTrue(ComposerKeyPolicy.submits(keyCode: 36, modifiers: [], composing: false))
        XCTAssertTrue(ComposerKeyPolicy.submits(keyCode: 76, modifiers: [], composing: false))
        XCTAssertTrue(ComposerKeyPolicy.submits(keyCode: 36, modifiers: .command, composing: false))
        XCTAssertFalse(ComposerKeyPolicy.submits(keyCode: 36, modifiers: .shift, composing: false))
        XCTAssertFalse(ComposerKeyPolicy.submits(keyCode: 36, modifiers: [], composing: true))
        XCTAssertFalse(ComposerKeyPolicy.submits(keyCode: 0, modifiers: [], composing: false))
    }
    func testAdaptiveHeightsAreBounded() {
        XCTAssertEqual(PanelMetrics.width, 480)
        XCTAssertEqual(PanelMetrics.promptHeight(inputHeight: 0), 50)
        XCTAssertEqual(PanelMetrics.promptHeight(inputHeight: 40), 62)
        XCTAssertEqual(PanelMetrics.promptHeight(inputHeight: 10_000), 126)
        XCTAssertEqual(PanelMetrics.answerHeight(textHeight: 20, question: false, availableHeight: 900), 152)
        XCTAssertEqual(PanelMetrics.answerHeight(textHeight: 10_000, question: true, availableHeight: 900), 500)
        XCTAssertLessThanOrEqual(PanelMetrics.answerHeight(textHeight: 10_000, question: true, availableHeight: 500), 394)
    }
    @MainActor func testNativeMarkdownStylesAndUnicode() {
        let result = AnswerRenderer.render("# Title\n\nA **bold** idea with *emphasis* and `code`.\n\n- First\n- 日本語 ü\n\n```swift\nlet x = 42\n```")
        XCTAssertTrue(result.string.hasPrefix("Title\nA bold idea"))
        XCTAssertTrue(result.string.contains("•\t日本語 ü"))
        XCTAssertTrue(result.string.contains("let x = 42"))
        XCTAssertFalse(result.string.contains("```"))
        let ns = result.string as NSString
        let heading = result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(heading?.pointSize, 21)
        let bold = result.attribute(.font, at: ns.range(of: "bold").location, effectiveRange: nil) as! NSFont
        XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
        let code = result.attribute(.font, at: ns.range(of: "code").location, effectiveRange: nil) as! NSFont
        XCTAssertTrue(code.isFixedPitch)
        XCTAssertLessThan(AnswerRenderer.measuredHeight(result, width: 612), AnswerRenderer.measuredHeight(result, width: 150))
    }
    @MainActor func testRenderedLinksCannotOpenFilesScriptsOrFetchImages() {
        let result = AnswerRenderer.render("[Docs](https://example.com/docs) [local](file:///etc/passwd) [script](javascript:alert(1)) ![alt](https://example.com/image.png)")
        var links: [URL] = []
        result.enumerateAttribute(.link, in: NSRange(location: 0, length: result.length)) { value, _, _ in
            if let url = value as? URL { links.append(url) }
        }
        XCTAssertEqual(links, [URL(string: "https://example.com/docs")!])
        result.enumerateAttribute(.attachment, in: NSRange(location: 0, length: result.length)) { value, _, _ in XCTAssertNil(value) }
        XCTAssertFalse(AnswerRenderer.safeLink(URL(string: "file:///tmp/example")!))
        XCTAssertFalse(AnswerRenderer.safeLink(URL(string: "javascript:alert(1)")!))
    }
    @MainActor func testMalformedMarkdownAndLongAnswersRemainReadable() {
        let source = "Unfinished **bold and `code\n\n1. A numbered item\n2. Another\n\n> Quoted text\n\n```\nunclosed code"
        let result = AnswerRenderer.render(source)
        XCTAssertTrue(result.string.contains("1.\tA numbered item"))
        XCTAssertTrue(result.string.contains("unclosed code"))
        XCTAssertGreaterThan(AnswerRenderer.measuredHeight(AnswerRenderer.render(String(repeating: source, count: 20)), width: 612), 580)
    }
    @MainActor func testLastAnswerSurvivesDismissalNewPromptAndError() {
        _ = NSApplication.shared
        let panel = PromptPanel()
        defer { panel.hide() }
        panel.reader("Keep **this answer**.")
        XCTAssertTrue(panel.hasLastAnswer)
        panel.hide()
        XCTAssertEqual(panel.mode, .hidden)
        let snapshot = Snapshot(cursor: Point(x: 0, y: 0), target: nil, underCursor: nil, monitors: [])
        panel.prompt(snapshot: snapshot, appName: "Test fixture")
        var permissionRequests = 0
        panel.onPermissions = { permissionRequests += 1 }
        panel.showFailure(DomainError("permission_denied", "Screen Recording is not allowed"))
        XCTAssertEqual(permissionRequests, 0, "Presenting an error must never request permission automatically")
        panel.hide()
        panel.reopenLastAnswer()
        XCTAssertEqual(panel.mode, .reader)
        XCTAssertEqual(panel.displayedAnswer, "Keep **this answer**.")
    }
    @MainActor func testPersistentReaderFollowupBusyAndRecallLifecycle() {
        _ = NSApplication.shared
        let panel = PromptPanel()
        defer { panel.hide() }
        panel.setFollowupEnabled(true)
        panel.reader("First answer", present: false)
        panel.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        XCTAssertEqual(panel.mode, .reader, "Deactivation must not close the conversation")
        var prompts: [String] = []
        panel.onFollowup = { prompts.append($0) }
        panel.setFollowupDraft(" \n ")
        XCTAssertFalse(panel.submitFollowup())
        panel.setFollowupDraft("Keep context\nsecond line")
        XCTAssertTrue(panel.submitFollowup())
        XCTAssertEqual(prompts, ["Keep context\nsecond line"])
        XCTAssertFalse(panel.submitFollowup(), "Busy submission must never be queued twice")
        panel.setFollowupEnabled(false)
        panel.hide()
        panel.reopenLastAnswer()
        XCTAssertFalse(panel.followupEnabled, "Recalled answer must not recreate a closed thread")
    }
    func testActionableFailureCopyWithoutChangingDomainCodes() {
        let permission = FailurePresentation(DomainError("permission_denied", "technical detail"))
        XCTAssertTrue(permission.offersPermissions)
        XCTAssertEqual(permission.title, "Let pi-os see this window")
        let gone = FailurePresentation(DomainError("target_gone", "technical detail"))
        XCTAssertFalse(gone.offersPermissions)
        XCTAssertTrue(gone.message.contains("Nothing else was captured"))
        let unknown = FailurePresentation(DomainError("new_code", "Useful failure detail"))
        XCTAssertEqual(unknown.message, "Useful failure detail")
    }
}
