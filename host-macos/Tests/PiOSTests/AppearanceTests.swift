import AppKit
import XCTest
@testable import PiOSCore
@testable import PiOSMac

final class AppearanceTests: XCTestCase {
    func testPresetAndSpacingDefaultsAreBounded() {
        XCTAssertEqual(AppearancePreset.allCases.map(\.rawValue), ["system", "clear", "frost", "graphite", "warm", "contrast"])
        XCTAssertEqual(AppearancePreferences().lowerInset, 32)
        for invalid in [Double.nan, .infinity, -1, 0, 20.5, 10_000] {
            XCTAssertEqual(AppearancePreferences(lowerInset: invalid).lowerInset, 32)
        }
    }
    func testAccessibilityAlwaysOverridesTranslucency() {
        for preset in AppearancePreset.allCases {
            let prefs = AppearancePreferences(preset: preset)
            XCTAssertTrue(prefs.opaque(systemReduceTransparency: true, systemIncreaseContrast: false))
            XCTAssertTrue(prefs.opaque(systemReduceTransparency: false, systemIncreaseContrast: true))
            XCTAssertEqual(prefs.opaque(systemReduceTransparency: false, systemIncreaseContrast: false), preset == .contrast)
        }
        XCTAssertTrue(AppearancePreferences(reduceTransparency: true).opaque(systemReduceTransparency: false, systemIncreaseContrast: false))
    }
    func testBottomPlacementIsDisplayCenteredAndGrowsUpward() {
        for area in [Rect(x: 0, y: 25, width: 1920, height: 1020), Rect(x: -1920, y: -450, width: 1920, height: 1080), Rect(x: 0, y: 1080, width: 1200, height: 780)] {
            let short = Placement.bottomPanel(width: 480, height: 50, workArea: area)
            let tall = Placement.bottomPanel(width: 480, height: 490, workArea: area)
            XCTAssertEqual(short.x + short.width / 2, area.x + area.width / 2)
            XCTAssertEqual(short.y, area.y + 32)
            XCTAssertEqual(short.y, tall.y, "Multiline/reader expansion must keep the lower edge fixed")
            XCTAssertTrue(area.contains(Point(x: tall.x, y: tall.y)))
            XCTAssertTrue(area.contains(Point(x: tall.x + tall.width, y: tall.y + tall.height)))
            XCTAssertEqual(Placement.bottomPanel(width: 480, height: 50, workArea: area, lowerInset: 48).y, area.y + 48)
        }
    }
    func testOversizePlacementRemainsInVisibleWorkArea() {
        let area = Rect(x: -400, y: 80, width: 390, height: 500)
        let placed = Placement.bottomPanel(width: 800, height: 10_000, workArea: area)
        XCTAssertTrue(area.contains(Point(x: placed.x, y: placed.y)))
        XCTAssertTrue(area.contains(Point(x: placed.x + placed.width, y: placed.y + placed.height)))
        XCTAssertEqual(placed.width, 366); XCTAssertEqual(placed.y, 112)
        XCTAssertEqual(placed.height, 456)
        XCTAssertFalse(Placement.bottomPanel(width: .nan, height: 50, workArea: area).valid)
    }
    @MainActor func testPreferencePersistenceCannotChangeSecuritySettings() {
        let defaults = UserDefaults(suiteName: "dev.pi-os.appearance-tests." + UUID().uuidString)!
        defaults.set(true, forKey: "allowCredentialFieldInput")
        defaults.set(false, forKey: "allowComputerControl")
        let settings = AppearanceSettings(defaults: defaults)
        XCTAssertEqual(settings.value, AppearancePreferences())
        settings.set(AppearancePreferences(preset: .warm, largerText: true, reduceTransparency: true, lowerInset: 48))
        XCTAssertEqual(AppearanceSettings(defaults: defaults).value, settings.value)
        XCTAssertTrue(defaults.bool(forKey: "allowCredentialFieldInput"))
        XCTAssertFalse(defaults.bool(forKey: "allowComputerControl"))
        defaults.set("unknown", forKey: "appearancePreset"); defaults.set(900, forKey: "appearanceLowerInset")
        XCTAssertEqual(settings.value.preset, .system); XCTAssertEqual(settings.value.lowerInset, 32)
    }
    @MainActor func testWhisperSingleLineMultilineAndDraftSurviveAppearanceChanges() {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let old = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(old, forName: UserDefaults.argumentDomain); NotificationCenter.default.post(name: AppearanceSettings.changed, object: nil) }
        defaults.setVolatileDomain(["appearancePreset": "frost", "appearanceLargerText": false], forName: UserDefaults.argumentDomain)
        let panel = PromptPanel(); defer { panel.hide() }
        panel.prompt(snapshot: Snapshot(cursor: Point(x: 0, y: 0), target: nil, underCursor: nil, monitors: []), appName: "Fixture")
        XCTAssertEqual(panel.displayedFrame.width, 480); XCTAssertEqual(panel.displayedFrame.height, 50)
        let bottom = panel.displayedFrame.minY
        XCTAssertTrue(panel.composerHasFocus)
        panel.setDraft("First line\nSecond line\n日本語 👩🏽‍💻")
        XCTAssertTrue(panel.composerHasFocus, "Per-keystroke layout must not hide the focused text receiver")
        XCTAssertGreaterThan(panel.displayedFrame.height, 50); XCTAssertEqual(panel.displayedFrame.minY, bottom)
        panel.setFollowupEnabled(true); panel.reader("Keep **this answer**.", present: false)
        panel.setFollowupDraft("Preserved draft")
        defaults.setVolatileDomain(["appearancePreset": "contrast", "appearanceLargerText": true], forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: AppearanceSettings.changed, object: nil)
        XCTAssertEqual(panel.displayedAnswer, "Keep **this answer**."); XCTAssertTrue(panel.followupEnabled)
        XCTAssertFalse(panel.nativeGlassVisible)
        XCTAssertEqual(panel.composerFrame.height, 62)
        var submitted: String?
        panel.onFollowup = { submitted = $0 }
        XCTAssertTrue(panel.submitFollowup()); XCTAssertEqual(submitted, "Preserved draft")
    }
    @MainActor func testNativeAppearanceControlsUseOnlyInjectedVisualPreferences() {
        _ = NSApplication.shared
        let defaults = UserDefaults(suiteName: "dev.pi-os.appearance-controls." + UUID().uuidString)!
        let settings = AppearanceSettings(defaults: defaults)
        let controller = AppearanceViewController(settings: settings)
        let view = controller.view
        let popups = view.subviews.compactMap { $0 as? NSPopUpButton }
        let preset = popups.first { $0.numberOfItems == 6 }!
        for (index, value) in AppearancePreset.allCases.enumerated() {
            preset.selectItem(at: index)
            XCTAssertTrue(NSApp.sendAction(preset.action!, to: preset.target, from: preset))
            XCTAssertEqual(settings.value.preset, value)
        }
        let buttons = view.subviews.compactMap { $0 as? NSButton }.filter { !($0 is NSPopUpButton) }
        let large = buttons.first { $0.title == "Larger text" }!
        large.state = .on; XCTAssertTrue(NSApp.sendAction(large.action!, to: large.target, from: large))
        XCTAssertTrue(settings.value.largerText)
        let spacing = popups.first { $0.numberOfItems == 3 }!
        spacing.selectItem(at: 2); XCTAssertTrue(NSApp.sendAction(spacing.action!, to: spacing.target, from: spacing))
        XCTAssertEqual(settings.value.lowerInset, 48)
        XCTAssertNil(defaults.object(forKey: "allowCredentialFieldInput"))
        XCTAssertNil(defaults.object(forKey: "allowComputerControl"))
    }
    @MainActor func testLargerMarkdownScalesWithoutChangingItsContentOrSafeLinks() {
        let source = "# Hello\n\n**World** & [docs](https://example.com/)"
        let regular = AnswerRenderer.render(source), large = AnswerRenderer.render(source, scale: 1.2)
        XCTAssertEqual(regular.string, large.string)
        XCTAssertEqual((large.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 25.2)
        XCTAssertGreaterThan(AnswerRenderer.measuredHeight(large, width: 436), AnswerRenderer.measuredHeight(regular, width: 436))
    }
}
