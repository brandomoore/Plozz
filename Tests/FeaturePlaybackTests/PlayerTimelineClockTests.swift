import XCTest
@testable import FeaturePlayback

final class PlayerTimelineClockTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 86_100)

    func testFinishEstimateTracksSpeedSeekingAndPauseTime() throws {
        XCTAssertEqual(try end(position: 600, duration: 4_200), now.addingTimeInterval(3_600))
        XCTAssertEqual(try end(position: 600, duration: 4_200, speed: 2), now.addingTimeInterval(1_800))
        XCTAssertEqual(try end(position: 600, duration: 4_200, speed: 0.5), now.addingTimeInterval(7_200))
        XCTAssertEqual(try end(position: 3_000, duration: 4_200), now.addingTimeInterval(1_200))
        XCTAssertEqual(PlayerClockTimes.estimatedEnd(
            now: now.addingTimeInterval(120), position: 600, duration: 4_200, speed: 1
        ), now.addingTimeInterval(3_720))
    }

    func testUnknownOrInvalidTimingHasNoFinishEstimate() {
        for duration in [0, -1, Double.nan, .infinity] {
            XCTAssertNil(PlayerClockTimes.estimatedEnd(now: now, position: 0, duration: duration, speed: 1))
        }
        for speed in [0, -1, Double.nan, .infinity, Double.leastNonzeroMagnitude] {
            XCTAssertNil(PlayerClockTimes.estimatedEnd(now: now, position: 0, duration: 600, speed: speed))
        }
        for position in [-1, Double.nan, .infinity] {
            XCTAssertNil(PlayerClockTimes.estimatedEnd(now: now, position: position, duration: 600, speed: 1))
        }
        XCTAssertNil(PlayerClockTimes.estimatedEnd(now: now, position: 0, duration: 1e20, speed: 1))
        XCTAssertEqual(PlayerClockTimes.estimatedEnd(now: now, position: 601, duration: 600, speed: 1), now)
    }

    func testLocalizedClockCrossesMidnightAndUsesSelectedTimeZone() throws {
        let english = labels(locale: "en_US", timeZone: .gmt)
        XCTAssertEqual(english.current, "11:55\u{202F}PM")
        XCTAssertEqual(english.endTime, "12:05\u{202F}AM")
        XCTAssertEqual(english.end.map { String(localized: $0) }, "Ends at 12:05\u{202F}AM")
        let british = labels(locale: "en_GB", timeZone: .gmt)
        XCTAssertEqual(british.current, "23:55")
        XCTAssertEqual(british.endTime, "0:05")
        XCTAssertEqual(british.end.map { String(localized: $0) }, "Ends at 0:05")
        let shifted = labels(locale: "en_GB", timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 3_600)))
        XCTAssertEqual(shifted.current, "0:55")
        XCTAssertEqual(shifted.end.map { String(localized: $0) }, "Ends at 1:05")
        XCTAssertEqual(british.currentWidthSamples, ["11:59", "23:59"])
        XCTAssertEqual(english.currentWidthSamples, ["11:59\u{202F}AM", "11:59\u{202F}PM"])
    }

    @MainActor
    func testClockModeStartsOffAndResetsWithTransportVisibility() {
        let model = PlayerControlsModel()
        XCTAssertFalse(model.timelineClock.isEnabled)
        model.controlsVisible = true
        model.timelineClock.isEnabled = true
        model.isScrubbing = true
        XCTAssertTrue(model.timelineClock.isEnabled, "Scrubbing temporarily changes labels, not the chosen mode.")
        model.isScrubbing = false
        model.controlsVisible = true
        XCTAssertTrue(model.timelineClock.isEnabled, "Rearming auto-hide must not reset the clock.")
        model.controlsVisible = false
        #if os(tvOS)
        XCTAssertTrue(model.timelineClock.isEnabled, "The outgoing controls must keep their clock labels.")
        #else
        XCTAssertFalse(model.timelineClock.isEnabled)
        #endif
        model.controlsVisible = true
        XCTAssertFalse(model.timelineClock.isEnabled)
    }

    func testHiddenClockSchedulesNoTicksAndVisibleClockTicksEverySecond() {
        XCTAssertTrue(Array(PlayerClockSchedule(paused: true).entries(from: now, mode: .normal).prefix(3)).isEmpty)
        XCTAssertEqual(
            Array(PlayerClockSchedule(paused: false).entries(from: now, mode: .normal).prefix(3)),
            [now, now.addingTimeInterval(1), now.addingTimeInterval(2)]
        )
    }

    @MainActor
    func testTimelineLabelsCompareTextAndIdentityRatherThanFractionalProgress() {
        let model = PlayerControlsModel()
        model.duration = 10
        func labels() -> PlayerTimelineLabels {
            PlayerTimelineLabels(
                model: model, curLabel: PlayerControls.timeLabel(model.displaySeconds),
                remLabel: "-" + PlayerControls.timeLabel(model.duration - model.displaySeconds), showsClock: false
            )
        }
        model.currentSeconds = 3.6
        let before = labels()
        model.currentSeconds = 4.4
        let after = labels()
        XCTAssertEqual(before, after)
        XCTAssertNotEqual(before, PlayerTimelineLabels(
            model: model, curLabel: "0:05", remLabel: "-0:06", showsClock: false
        ))
        XCTAssertNotEqual(before, PlayerTimelineLabels(
            model: model, curLabel: "0:04", remLabel: "-0:07", showsClock: false
        ))
        XCTAssertNotEqual(before, PlayerTimelineLabels(
            model: model, curLabel: "0:04", remLabel: "-0:06", showsClock: true
        ))
        XCTAssertNotEqual(before, PlayerTimelineLabels(
            model: PlayerControlsModel(), curLabel: "0:04", remLabel: "-0:06", showsClock: false
        ))
    }

    private func end(position: Double, duration: Double, speed: Double = 1) throws -> Date {
        try XCTUnwrap(PlayerClockTimes.estimatedEnd(now: now, position: position, duration: duration, speed: speed))
    }

    private func labels(locale: String, timeZone: TimeZone) -> PlayerClockTimes {
        PlayerClockTimes(
            now: now, position: 0, duration: 600, speed: 1,
            locale: Locale(identifier: locale), timeZone: timeZone
        )
    }
}

final class RemoteTapInterpreterTests: XCTestCase {
    func testStationaryTapIsRecognizedOnlyOnReleaseAndOnlyOnce() {
        var tap = RemoteTapInterpreter()
        tap.began(at: .zero, timestamp: 10)
        tap.moved(to: CGPoint(x: 3, y: 4))
        XCTAssertTrue(tap.ended(at: CGPoint(x: 3, y: 4), timestamp: 10.2))
        XCTAssertFalse(tap.ended(at: .zero, timestamp: 10.21))
    }

    func testSwipeCannotBecomeATapEvenAfterReturningToItsOrigin() {
        for point in [CGPoint(x: 10, y: 0), CGPoint(x: 0, y: -10), CGPoint(x: 8, y: 8)] {
            var tap = RemoteTapInterpreter()
            tap.began(at: .zero, timestamp: 1)
            tap.moved(to: point)
            tap.moved(to: .zero)
            XCTAssertFalse(tap.ended(at: .zero, timestamp: 1.2))
        }
    }

    func testCoalescedSwipeAndHeldContactAreNotTaps() {
        var tap = RemoteTapInterpreter()
        tap.began(at: .zero, timestamp: 1)
        XCTAssertFalse(tap.ended(at: CGPoint(x: 100, y: 0), timestamp: 1.1))
        tap.began(at: .zero, timestamp: 1)
        XCTAssertFalse(tap.ended(at: .zero, timestamp: 1.36))
    }

    func testCancelledAndClickedContactsCannotToggleButNextTapCan() {
        var tap = RemoteTapInterpreter()
        tap.began(at: .zero, timestamp: 1)
        tap.cancel()
        XCTAssertFalse(tap.ended(at: .zero, timestamp: 1.1))
        tap.began(at: .zero, timestamp: 2)
        XCTAssertTrue(tap.ended(at: .zero, timestamp: 2.1))
    }

    func testInvalidInputIsNotATap() {
        var tap = RemoteTapInterpreter()
        for timestamp in [Double.nan, .infinity, -1] {
            tap.began(at: .zero, timestamp: 1)
            XCTAssertFalse(tap.ended(at: .zero, timestamp: timestamp))
        }
        tap.began(at: CGPoint(x: CGFloat.nan, y: 0), timestamp: 1)
        XCTAssertFalse(tap.ended(at: .zero, timestamp: 1.1))
    }
}
