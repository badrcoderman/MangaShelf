import XCTest
@testable import ReaderCore

final class ReaderLayoutTests: XCTestCase {
    func testSpreadPairingPreservesEveryPageAndBlankBeforeSingle() {
        let spreads = ReaderSpreadLayout.build(pageCount: 7, doublePages: true, separateCover: false, singlePages: [1, 4])
        XCTAssertEqual(spreads.map(\.pages), [[0], [1], [2, 3], [4], [5, 6]])
        XCTAssertEqual(spreads.map(\.fullWidth), [false, true, false, true, false])
        XCTAssertEqual(spreads.flatMap(\.pages), Array(0..<7))
    }

    func testCoverAndOddFinalSlotAreDistinct() {
        let cover = ReaderSpreadLayout.build(pageCount: 6, doublePages: true)
        XCTAssertEqual(cover.map(\.pages), [[0], [1, 2], [3, 4], [5]])
        XCTAssertTrue(cover[0].fullWidth)
        XCTAssertFalse(cover[3].fullWidth)
        let singles = ReaderSpreadLayout.build(pageCount: 5, doublePages: false)
        XCTAssertTrue(singles.allSatisfy(\.fullWidth))
        XCTAssertEqual(singles.flatMap(\.pages), Array(0..<5))
        XCTAssertTrue(ReaderSpreadLayout.build(pageCount: 0, doublePages: true).isEmpty)
    }

    func testRePairingAfterDiscoveringLandscapeKeepsTheSamePageReachable() {
        let before = ReaderSpreadLayout.build(pageCount: 8, doublePages: true)
        let after = ReaderSpreadLayout.build(pageCount: 8, doublePages: true, singlePages: [2, 3, 6])
        XCTAssertEqual(before.flatMap(\.pages), after.flatMap(\.pages))
        XCTAssertEqual(after.filter { $0.pages.contains(3) }.count, 1)
        XCTAssertTrue(after.first { $0.pages.contains(3) }!.fullWidth)
    }

    func testAllTwoDimensionalTapLayoutsAndIndependentWebtoonSelection() {
        var settings = ReaderSettings(); settings.tapNavigation = true; settings.direction = .leftToRight
        let layouts: [(ReaderTapLayout, [Int])] = [
            (.lShaped, [-1, -1, -1, -1, 0, 1, 1, 1, 1]),
            (.rightAndLeft, [-1, 0, 1, -1, 0, 1, -1, 0, 1]),
            (.edge, [1, 0, 1, 1, 0, 1, 1, -1, 1]),
            (.kindlish, [0, 0, 0, -1, 1, 1, -1, 1, 1])
        ]
        for (layout, expected) in layouts {
            settings.tapLayout = layout
            let actual = (0..<9).map { settings.pageStep(x: (Double($0 % 3) + 0.5) / 3, y: (Double($0 / 3) + 0.5) / 3) }
            XCTAssertEqual(actual, expected, "\(layout)")
        }
        settings.mode = .webtoon; settings.tapLayout = .edge
        XCTAssertEqual(settings.pageStep(x: 0.1, y: 0.5), 0)
        settings.webtoonTapLayout = .kindlish
        XCTAssertEqual(settings.pageStep(x: 0.5, y: 0.8), 1)
        XCTAssertEqual(settings.pageStep(x: 0.5, y: 0.8, temporarilyDisabled: true), 0)
        XCTAssertEqual(settings.pageStep(x: .nan, y: 0.5), 0)
        XCTAssertEqual(settings.pageStep(x: 1.01, y: 0.5), 0)
    }

    func testTapInversionUsesSeparatePoliciesForHorizontalAndOtherLayouts() {
        var settings = ReaderSettings(); settings.tapNavigation = true
        for direction in ReadingDirection.allCases {
            for invert in [false, true] {
                settings.direction = direction; settings.invertTap = invert; settings.tapLayout = .rightAndLeft
                XCTAssertEqual(settings.pageStep(x: 0.1, y: 0.5), direction == .rightToLeft ? 1 : -1)
                settings.tapLayout = .lShaped
                XCTAssertEqual(settings.pageStep(x: 0.5, y: 0.1), invert ? 1 : -1)
            }
        }
    }

    func testNormalizedResumeSurvivesAWidthChangeAndRejectsInvalidValues() throws {
        let position = ReaderResumePosition(page: 12, offset: 0.375)
        XCTAssertEqual(position.distance(pageHeight: 2400), 900)
        XCTAssertEqual(position.distance(pageHeight: 1200), 450)
        let reopened = try JSONDecoder().decode(ReaderResumePosition.self, from: JSONEncoder().encode(position))
        XCTAssertEqual(reopened, position)
        XCTAssertEqual(ReaderResumePosition(page: -2, offset: .nan), ReaderResumePosition(page: 0))
        XCTAssertEqual(ReaderResumePosition(page: 2, offset: 1.5).offset, 1)
        let invalid = try JSONDecoder().decode(ReaderResumePosition.self, from: Data(#"{"page":-1,"offset":2}"#.utf8))
        XCTAssertEqual(invalid, ReaderResumePosition(page: 0, offset: 1))
    }

    func testHoldSpeedHasHysteresisAndCanCrossMultipleLevels() {
        XCTAssertEqual(ReaderHoldScrollSpeed.level(current: 4, deltaY: -41), 4)
        XCTAssertEqual(ReaderHoldScrollSpeed.level(current: 4, deltaY: -42), 3)
        XCTAssertEqual(ReaderHoldScrollSpeed.level(current: 3, deltaY: -19), 3)
        XCTAssertEqual(ReaderHoldScrollSpeed.level(current: 3, deltaY: -18), 4)
        XCTAssertEqual(ReaderHoldScrollSpeed.level(current: 4, deltaY: 71), 4)
        XCTAssertEqual(ReaderHoldScrollSpeed.level(current: 4, deltaY: 72), 5)
        XCTAssertEqual(ReaderHoldScrollSpeed.level(current: 4, deltaY: -300), 0)
        XCTAssertEqual(ReaderHoldScrollSpeed.level(current: 4, deltaY: 300), 7)
        XCTAssertEqual(ReaderHoldScrollSpeed.factors[4], 1)
    }

    func testLegacyMigrationAndPerTitleReaderOptionsRoundTrip() throws {
        let legacy = try JSONDecoder().decode(ReaderSettings.self, from: Data(#"{"tapNavigation":true,"direction":"leftToRight"}"#.utf8))
        XCTAssertEqual(legacy.tapLayout, .rightAndLeft)
        XCTAssertEqual(legacy.webtoonTapLayout, .disabled)
        XCTAssertEqual(legacy.spreadMode, .single)
        XCTAssertTrue(legacy.doubleTapZoom)
        var custom = legacy
        custom.rotation = .landscape; custom.background = .sepia; custom.pageSpacing = 13
        custom.sidePadding = 0.08; custom.cropBorders = true; custom.cropInsets.left = 0.04
        custom.spreadMode = .double; custom.invertDoublePages = true; custom.webtoonTapLayout = .lShaped
        var state = LibraryState(); state.readerOverrides["online:source:title"] = custom
        let decoded = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.readerSettings(for: "online:source:title"), custom)
        XCTAssertEqual(decoded.settings, ReaderSettings())
        let invalid = try JSONDecoder().decode(ReaderSettings.self, from: Data(#"{"sidePadding":4,"pageSpacing":-4,"dimming":2,"autoScrollSpeed":2000,"cropInsets":{"top":-1,"left":4,"right":0,"bottom":0}}"#.utf8))
        XCTAssertEqual(invalid.sidePadding, 0.25); XCTAssertEqual(invalid.pageSpacing, 0)
        XCTAssertEqual(invalid.dimming, 0.75); XCTAssertEqual(invalid.autoScrollSpeed, 200)
        XCTAssertEqual(invalid.cropInsets.top, 0); XCTAssertEqual(invalid.cropInsets.left, 0.25)
    }
}
