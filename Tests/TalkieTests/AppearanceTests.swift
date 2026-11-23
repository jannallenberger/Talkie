import AppKit
import SwiftUI
import XCTest
@testable import Talkie

/// The v3 look: the appearance store, the backdrop gradient's geometry, accent
/// contrast, the dashboard grid and chart colours, the slider, and the small
/// meeting-notes window's pure rules.
@MainActor
final class AppearanceTests: XCTestCase {

    private func makeDefaults() -> (UserDefaults, String) {
        let name = "talkie-appearance-tests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    // MARK: Store

    func testStoreStartsWithTheShippedLook() {
        let (d, name) = makeDefaults()
        defer { d.removePersistentDomain(forName: name) }
        XCTAssertEqual(AppearanceStore(defaults: d).look, TalkieLook())
        // Talkie ships in ember, as a whisper on clear glass.
        XCTAssertEqual(TalkieLook().backdrop, .ember)
        XCTAssertEqual(TalkieLook().glass, .clear)
        XCTAssertEqual(TalkieLook().accent, .ember)
        XCTAssertEqual(TalkieLook().intensity, 0)
        XCTAssertEqual(TalkieLook().angle, 111)
    }

    func testStorePersistsEveryChoice() {
        let (d, name) = makeDefaults()
        defer { d.removePersistentDomain(forName: name); ThemeState.adopt(TalkieLook()) }
        let store = AppearanceStore(defaults: d)
        store.update {
            $0.accent = .green
            $0.backdrop = .lagoon
            $0.intensity = 0.8
            $0.angle = 300
            $0.variesByPage = false
            $0.glass = .clear
        }
        let reloaded = AppearanceStore(defaults: d).look
        XCTAssertEqual(reloaded.accent, .green)
        XCTAssertEqual(reloaded.backdrop, .lagoon)
        XCTAssertEqual(reloaded.intensity, 0.8, accuracy: 0.0001)
        XCTAssertEqual(reloaded.angle, 300, accuracy: 0.0001)
        XCTAssertFalse(reloaded.variesByPage)
        XCTAssertEqual(reloaded.glass, .clear)
    }

    func testStoreClampsOutOfRangeValues() {
        let (d, name) = makeDefaults()
        defer { d.removePersistentDomain(forName: name); ThemeState.adopt(TalkieLook()) }
        let store = AppearanceStore(defaults: d)
        store.update { $0.intensity = 7; $0.angle = -90 }
        XCTAssertEqual(store.look.intensity, 1)
        XCTAssertEqual(store.look.angle, 270)
        store.update { $0.intensity = .nan; $0.angle = 725 }
        XCTAssertEqual(store.look.intensity, 0.5)
        XCTAssertEqual(store.look.angle, 5, accuracy: 0.0001)
    }

    func testUnknownStoredValuesFallBackToDefaults() {
        let (d, name) = makeDefaults()
        defer { d.removePersistentDomain(forName: name) }
        d.set("ultraviolet", forKey: "appearanceAccent")
        d.set("liquid-metal", forKey: "appearanceGlass")
        let look = AppearanceStore(defaults: d).look
        XCTAssertEqual(look.accent, TalkieLook().accent)
        XCTAssertEqual(look.glass, TalkieLook().glass)
    }

    func testThemeTokensFollowTheAccentAndFlatSurfaces() {
        defer { ThemeState.adopt(TalkieLook()) }
        var look = TalkieLook()
        look.accent = .red
        ThemeState.adopt(look)
        XCTAssertEqual(ThemeState.accent, .red)
        XCTAssertFalse(ThemeState.flatSurfaces, "glass over a gradient: frosted tiles")
        look.glass = .solid
        ThemeState.adopt(look)
        XCTAssertTrue(ThemeState.flatSurfaces)
        look.glass = .frosted
        look.backdrop = .plain
        ThemeState.adopt(look)
        XCTAssertTrue(ThemeState.flatSurfaces, "a frosted white tile would vanish on the plain canvas")
    }

    // MARK: Backdrop geometry

    func testGradientRunsCornerToCornerAndEdgeToEdge() {
        let right = TalkieBackdropGeometry.points(degrees: 0)
        XCTAssertEqual(right.start.x, 0, accuracy: 1e-9); XCTAssertEqual(right.end.x, 1, accuracy: 1e-9)
        XCTAssertEqual(right.start.y, 0.5, accuracy: 1e-9); XCTAssertEqual(right.end.y, 0.5, accuracy: 1e-9)
        let down = TalkieBackdropGeometry.points(degrees: 90)
        XCTAssertEqual(down.start.y, 0, accuracy: 1e-9); XCTAssertEqual(down.end.y, 1, accuracy: 1e-9)
        let diagonal = TalkieBackdropGeometry.points(degrees: 45)
        XCTAssertEqual(diagonal.start.x, 0, accuracy: 1e-9); XCTAssertEqual(diagonal.start.y, 0, accuracy: 1e-9)
        XCTAssertEqual(diagonal.end.x, 1, accuracy: 1e-9); XCTAssertEqual(diagonal.end.y, 1, accuracy: 1e-9)
    }

    func testEveryAngleCoversTheWholePage() {
        // The start and end sit on (or outside) the unit square's boundary, mirrored
        // through its centre: no angle leaves a corner without colour.
        for degrees in stride(from: 0.0, to: 360.0, by: 15.0) {
            let p = TalkieBackdropGeometry.points(degrees: degrees)
            XCTAssertEqual(p.start.x + p.end.x, 1, accuracy: 1e-9)
            XCTAssertEqual(p.start.y + p.end.y, 1, accuracy: 1e-9)
            let reach = max(abs(p.start.x - 0.5), abs(p.start.y - 0.5))
            XCTAssertGreaterThanOrEqual(reach, 0.5 - 1e-9, "angle \(degrees)")
        }
    }

    func testPagesTurnTheGradientOnlyWhenAsked() {
        XCTAssertEqual(TalkieBackdropGeometry.angle(base: 135, turn: 0, variesByPage: true), 135)
        XCTAssertEqual(TalkieBackdropGeometry.angle(base: 135, turn: 2, variesByPage: true), 215)
        XCTAssertEqual(TalkieBackdropGeometry.angle(base: 135, turn: 6, variesByPage: true), 15, "wraps past 360")
        XCTAssertEqual(TalkieBackdropGeometry.angle(base: 135, turn: 6, variesByPage: false), 135)
    }

    func testEveryTabHasItsOwnTurn() {
        let turns = SettingsTab.allCases.map(\.backdropTurn)
        XCTAssertEqual(Set(turns).count, SettingsTab.allCases.count)
    }

    func testStrengthIsMonotonicAndNeverOpaque() {
        for dark in [false, true] {
            var last = -1.0
            for step in 0...10 {
                let o = TalkieBackdropGeometry.opacity(intensity: Double(step) / 10, dark: dark)
                XCTAssertGreaterThan(o, last)
                XCTAssertGreaterThan(o, 0.05, "even the softest setting shows the colours")
                XCTAssertLessThan(o, 0.55, "text must stay readable at the most vivid setting")
                last = o
            }
        }
    }

    func testMacawBackdropUsesAllFourLogoColours() {
        XCTAssertEqual(TalkieBackdropStyle.macaw.colors.count, 4)
        XCTAssertTrue(TalkieBackdropStyle.plain.colors.isEmpty)
        for style in TalkieBackdropStyle.allCases where style != .plain {
            XCTAssertGreaterThanOrEqual(style.colors.count, 2, "\(style) is a gradient")
        }
    }

    // MARK: Accent contrast

    private func rgb(_ color: Color, dark: Bool) -> (Double, Double, Double) {
        var out = (0.0, 0.0, 0.0)
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let c = NSColor(color).usingColorSpace(.sRGB)!
            out = (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        }
        return out
    }

    private func luminance(_ c: (Double, Double, Double)) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.0) + 0.7152 * lin(c.1) + 0.0722 * lin(c.2)
    }

    private func contrast(_ a: Color, _ b: Color, dark: Bool) -> Double {
        let la = luminance(rgb(a, dark: dark)), lb = luminance(rgb(b, dark: dark))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    func testEveryAccentCarriesReadableButtonTextInLightMode() {
        for accent in TalkieAccent.allCases {
            let p = accent.palette
            XCTAssertGreaterThanOrEqual(contrast(p.base, p.on, dark: false), 4.5, "\(accent) light")
        }
    }

    func testLightFeathersUseInkInDarkMode() {
        // White on dark-mode gold or green is unreadable; they carry ink instead.
        for accent in [TalkieAccent.gold, .green, .ember] {
            let p = accent.palette
            XCTAssertGreaterThanOrEqual(contrast(p.base, p.on, dark: true), 4.5, "\(accent) dark")
        }
    }

    func testAccentLinksAreReadableOnTheCanvas() {
        for accent in TalkieAccent.allCases {
            XCTAssertGreaterThanOrEqual(contrast(accent.palette.base, Theme.canvas, dark: false), 4.5, "\(accent) light")
            XCTAssertGreaterThanOrEqual(contrast(accent.palette.base, Theme.canvas, dark: true), 4.5, "\(accent) dark")
        }
    }

    // MARK: Dashboard grid and chart colours

    func testBentoRowSharesTheWidthByWeight() {
        // A third and two thirds of what is left after the gap.
        let w = BentoRow.widths(total: 614, weights: [4, 8], spacing: 14)
        XCTAssertEqual(w[0], 200, accuracy: 1e-9)
        XCTAssertEqual(w[1], 400, accuracy: 1e-9)
        // Four equal tiles fill the row exactly: nothing is orphaned.
        let tiles = BentoRow.widths(total: 614, weights: [1, 1, 1, 1], spacing: 14)
        XCTAssertEqual(tiles.reduce(0, +) + 3 * 14, 614, accuracy: 1e-9)
        XCTAssertEqual(Set(tiles.map { ($0 * 1000).rounded() }).count, 1)
        XCTAssertTrue(BentoRow.widths(total: 600, weights: [], spacing: 14).isEmpty)
        XCTAssertEqual(BentoRow.widths(total: 10, weights: [1, 1, 1], spacing: 14), [0, 0, 0],
                       "narrower than its gaps: never negative")
    }

    func testChartAverageCountsOnlyDaysWithDictation() {
        XCTAssertEqual(DashboardChartMath.activeDayAverage([0, 300, 0, 500, 0]), 400)
        XCTAssertNil(DashboardChartMath.activeDayAverage([0, 0, 900, 0]), "one day is not an average")
        XCTAssertNil(DashboardChartMath.activeDayAverage([]))
    }

    func testSharesAddUpAndSurviveAnEmptyTotal() {
        let shares = DashboardChartMath.shares([9, 12, 48])
        XCTAssertEqual(shares.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(shares[2], 48.0 / 69.0, accuracy: 1e-9)
        XCTAssertEqual(DashboardChartMath.shares([0, 0, 0]), [0, 0, 0])
    }

    func testChartsTakeTheirColoursFromTheBackdrop() {
        defer { ThemeState.adopt(TalkieLook()) }
        var look = TalkieLook()
        for style in TalkieBackdropStyle.allCases {
            look.backdrop = style
            ThemeState.adopt(look)
            XCTAssertEqual(Theme.dataColors.count, style.dataColors.count)
            XCTAssertGreaterThanOrEqual(Theme.dataColors.count, 2, "\(style): a ramp needs two colours")
        }
        XCTAssertEqual(TalkieBackdropStyle.macaw.dataColors.count, 4, "all four feathers")
    }

    func testDataRampEndsAtItsOwnColoursAndWrapsItsSeries() {
        defer { ThemeState.adopt(TalkieLook()) }
        var look = TalkieLook()
        look.backdrop = .ember
        ThemeState.adopt(look)
        XCTAssertEqual(rgb(Theme.dataColor(at: 0), dark: false).0, rgb(Theme.featherGold, dark: false).0, accuracy: 0.01)
        XCTAssertEqual(rgb(Theme.dataColor(at: 1), dark: false).1, rgb(Theme.featherRed, dark: false).1, accuracy: 0.01)
        XCTAssertEqual(rgb(Theme.dataColor(at: 7), dark: false).1, rgb(Theme.featherRed, dark: false).1, accuracy: 0.01,
                       "clamped past the end")
        XCTAssertEqual(rgb(Theme.dataColor(series: 2), dark: false).0, rgb(Theme.dataColor(series: 0), dark: false).0,
                       accuracy: 0.001, "two colours: the third series wears the first again")
    }

    func testEveryBackdropBringsAnAccent() {
        XCTAssertEqual(TalkieBackdropStyle.ember.accent, .ember)
        XCTAssertEqual(TalkieBackdropStyle.lagoon.accent, .green)
        XCTAssertEqual(TalkieBackdropStyle.dusk.accent, .plum)
        XCTAssertEqual(TalkieBackdropStyle.macaw.accent, .blue)
        XCTAssertNotEqual(TalkieLook().paintKey, { var l = TalkieLook(); l.backdrop = .lagoon; return l.paintKey }(),
                          "a new backdrop repaints pages")
    }

    // MARK: Slider

    func testSliderFollowsThePointerAcrossTheTrack() {
        // 220 wide, 20 thumb: the thumb's centre travels from x 10 to x 210.
        XCTAssertEqual(TalkieSliderMath.value(atX: 10, width: 220, thumb: 20, range: 0...1, step: nil), 0, accuracy: 1e-9)
        XCTAssertEqual(TalkieSliderMath.value(atX: 110, width: 220, thumb: 20, range: 0...1, step: nil), 0.5, accuracy: 1e-9)
        XCTAssertEqual(TalkieSliderMath.value(atX: 210, width: 220, thumb: 20, range: 0...1, step: nil), 1, accuracy: 1e-9)
    }

    func testSliderClampsOutsideTheTrackAndSnapsToSteps() {
        XCTAssertEqual(TalkieSliderMath.value(atX: -80, width: 220, thumb: 20, range: 0...359, step: 1), 0)
        XCTAssertEqual(TalkieSliderMath.value(atX: 900, width: 220, thumb: 20, range: 0...359, step: 1), 359)
        let v = TalkieSliderMath.value(atX: 77.3, width: 220, thumb: 20, range: 0...359, step: 1)
        XCTAssertEqual(v, v.rounded(), "whole degrees")
    }

    func testSliderThumbSitsWhereTheValueIs() {
        XCTAssertEqual(TalkieSliderMath.thumbOffset(value: 0, width: 220, thumb: 20, range: 0...1), 0)
        XCTAssertEqual(TalkieSliderMath.thumbOffset(value: 1, width: 220, thumb: 20, range: 0...1), 200)
        XCTAssertEqual(TalkieSliderMath.thumbOffset(value: 0.25, width: 220, thumb: 20, range: 0...1), 50)
        // A drag lands the thumb back under the pointer.
        let value = TalkieSliderMath.value(atX: 64, width: 220, thumb: 20, range: 0...1, step: nil)
        XCTAssertEqual(TalkieSliderMath.thumbOffset(value: value, width: 220, thumb: 20, range: 0...1) + 10, 64, accuracy: 1e-6)
    }

    func testSliderKeyboardStepsStayInRange() {
        XCTAssertEqual(TalkieSliderMath.nudged(0.5, by: 1, range: 0...1, step: nil), 0.55, accuracy: 1e-9)
        XCTAssertEqual(TalkieSliderMath.nudged(0.98, by: 1, range: 0...1, step: nil), 1)
        XCTAssertEqual(TalkieSliderMath.nudged(0, by: -1, range: 0...359, step: 1), 0)
        XCTAssertEqual(TalkieSliderMath.nudged(135, by: 1, range: 0...359, step: 1), 136)
    }

    // MARK: Meeting-notes window

    func testNotesWindowOpensBesideACallButNotOverTheMainWindow() {
        XCTAssertTrue(MeetingNotesWindowController.shouldOpenAutomatically(
            settingOn: true, mainWindowInFront: false, alreadyVisible: false))
        XCTAssertFalse(MeetingNotesWindowController.shouldOpenAutomatically(
            settingOn: true, mainWindowInFront: true, alreadyVisible: false),
            "the Meetings page already shows the notes editor")
        XCTAssertFalse(MeetingNotesWindowController.shouldOpenAutomatically(
            settingOn: false, mainWindowInFront: false, alreadyVisible: false))
        XCTAssertFalse(MeetingNotesWindowController.shouldOpenAutomatically(
            settingOn: true, mainWindowInFront: false, alreadyVisible: true))
    }

    func testTurnLogTailCopiesOnlyWhenSomethingNewWasSaid() {
        let log = TurnLog(startedAt: Date())
        XCTAssertNil(log.tail(40, ifCountDiffersFrom: 0))
        log.add(.me, "First", at: 1, end: 2)
        log.add(.them, "Second", at: 3, end: 4)
        log.add(.me, "Third", at: 5, end: 6)
        let tail = log.tail(2, ifCountDiffersFrom: 0)
        XCTAssertEqual(tail?.count, 3)
        XCTAssertEqual(tail?.turns.map(\.text), ["Second", "Third"])
        XCTAssertNil(log.tail(2, ifCountDiffersFrom: 3), "nothing new: nothing copied")
    }

    func testLiveTailKeepsSpokenOrderAndStableIdentity() {
        // The far end finalizes late: its turn arrives after a later mic turn.
        let turns: [TurnLog.Turn] = [
            .init(elapsed: 20, speaker: .me, text: "B"),
            .init(elapsed: 12, speaker: .them, text: "A"),
            .init(elapsed: 31, speaker: .me, text: "C"),
        ]
        let lines = LiveTranscriptTail.lines(from: turns, totalCount: 10)
        XCTAssertEqual(lines.map(\.text), ["A", "B", "C"])
        XCTAssertEqual(lines.map(\.id), [8, 7, 9], "ids are the turns' places in the whole log")
    }

    func testLiveTailRefreshesFromTheLog() {
        let log = TurnLog(startedAt: Date())
        let tail = LiveTranscriptTail()
        tail.refresh(from: log)
        XCTAssertTrue(tail.lines.isEmpty)
        log.add(.them, "Shall we start?", at: 2, end: 4)
        tail.refresh(from: log)
        XCTAssertEqual(tail.lines.map(\.text), ["Shall we start?"])
        XCTAssertEqual(tail.lines.first?.speaker, .them)
        tail.reset()
        XCTAssertTrue(tail.lines.isEmpty)
        tail.refresh(from: log)
        XCTAssertEqual(tail.lines.count, 1, "after a reset the next refresh picks the log up again")
    }

    func testNotesDraftBoxResets() {
        let box = NotesDraftBox()
        box.text = "Budget"
        box.lines = [.init(text: "Budget", seconds: 12)]
        box.isLive = true
        box.reset()
        XCTAssertEqual(box.text, "")
        XCTAssertTrue(box.lines.isEmpty)
        XCTAssertFalse(box.isLive)
    }
}
