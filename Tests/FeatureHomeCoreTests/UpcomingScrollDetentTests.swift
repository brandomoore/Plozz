#if os(iOS)
@testable import FeatureHomeCore
import CoreUI
import UIKit
import XCTest

final class UpcomingScrollDetentTests: XCTestCase {
    func testPastRequiresADeliberatePullButFutureScrollingIsUnchanged() {
        var drag = UpcomingScrollDetentDrag(start: 1_000, translation: 0, today: 1_000)
        XCTAssertGreaterThan(drag.offset(translation: 40), 990)
        XCTAssertLessThan(drag.offset(translation: 40), 1_000)
        XCTAssertTrue(drag.shouldSnap(offset: 987, translation: 40, velocity: -600))
        XCTAssertEqual(drag.offset(translation: -80), 1_080)
        XCTAssertFalse(drag.shouldSnap(offset: 1_080, translation: -80, velocity: 600))
        XCTAssertGreaterThan(drag.offset(translation: 239), 976)
        XCTAssertTrue(drag.shouldSnap(offset: drag.offset(translation: 239), translation: 239, velocity: -2_000))
        XCTAssertEqual(drag.advance(translation: 240), .pop)
        XCTAssertEqual(drag.offset(translation: 240), 976)
        XCTAssertFalse(drag.shouldSnap(offset: 976, translation: 240, velocity: 0))
    }

    func testResistanceIsContinuousAndRegainsFingerSpeed() {
        var drag = UpcomingScrollDetentDrag(start: 1_000, translation: 0, today: 1_000)
        var previous = drag.offset(translation: 0)
        for pull in 1...360 {
            _ = drag.advance(translation: CGFloat(pull))
            let next = drag.offset(translation: CGFloat(pull))
            XCTAssertGreaterThan(previous - next, 0)
            XCTAssertLessThanOrEqual(previous - next, 1.001)
            if pull <= 240 { XCTAssertGreaterThanOrEqual(next, 976) }
            previous = next
        }
        XCTAssertEqual(drag.offset(translation: 240), 976, accuracy: 0.001)
        XCTAssertEqual(drag.offset(translation: 241), 975, accuracy: 0.001)
        for pull in stride(from: 240, through: -40, by: -1) {
            XCTAssertEqual(
                drag.offset(translation: CGFloat(pull - 1)) - drag.offset(translation: CGFloat(pull)),
                1, accuracy: 0.001, "Reversing after the pop must remain 1:1, including across Today"
            )
        }
    }

    func testOnlyNearbyReleasesSnapAndHistoryIsNotTrapped() {
        let history = UpcomingScrollDetentDrag(start: 700, translation: 0, today: 1_000)
        XCTAssertEqual(history.offset(translation: 80), 620)
        XCTAssertTrue(history.shouldSnap(offset: 970, translation: -270, velocity: 600))
        XCTAssertTrue(history.shouldSnap(offset: 1_035, translation: -335, velocity: -600))
        XCTAssertFalse(history.shouldSnap(offset: 850, translation: -150, velocity: 0))
        XCTAssertFalse(history.shouldSnap(offset: 1_035, translation: -335, velocity: 2_000))
        var future = UpcomingScrollDetentDrag(start: 1_300, translation: 0, today: 1_000)
        XCTAssertFalse(future.shouldSnap(offset: 1_200, translation: 100, velocity: -2_000))
        XCTAssertTrue(future.shouldSnap(offset: 1_030, translation: 270, velocity: -600))
        XCTAssertTrue(future.shouldSnap(offset: future.offset(translation: 450), translation: 450, velocity: -600))
        XCTAssertEqual(future.advance(translation: 540), .pop)
        XCTAssertFalse(future.shouldSnap(offset: future.offset(translation: 540), translation: 540, velocity: 0))
    }

    @MainActor
    func testPullFeedbackBuildsToOnePopAndReleasedHistoryDoesNotRecatch() throws {
        try withDetent { detent, scroll, _ in
            var events: [TouchFeedback.Event] = []
            detent.onFeedback = { events.append($0) }
            scroll.contentOffset.y = 1_000
            detent.phaseChanged(to: .interacting)
            for pull in 1...239 {
                scroll.testPan.setTranslation(CGPoint(x: 0, y: CGFloat(pull)), in: scroll.window)
                scroll.contentOffset.y = 1_000 - CGFloat(pull)
                XCTAssertGreaterThanOrEqual(scroll.contentOffset.y, 976)
            }
            let intensities = events.compactMap { event -> Double? in
                if case let .tension(intensity) = event { return intensity }
                return nil
            }
            XCTAssertEqual(intensities.count, 7, "Feedback must follow pull milestones, not every scroll update")
            XCTAssertEqual(events.count, intensities.count)
            XCTAssertLessThan(try XCTUnwrap(intensities.first), 0.3)
            XCTAssertGreaterThan(try XCTUnwrap(intensities.last), 0.8)
            XCTAssertTrue(zip(intensities, intensities.dropFirst()).allSatisfy { $0.0 < $0.1 })
            for pull in [239, 210, 239] {
                scroll.testPan.setTranslation(CGPoint(x: 0, y: CGFloat(pull)), in: scroll.window)
                scroll.contentOffset.y = 1_000 - CGFloat(pull)
            }
            XCTAssertEqual(events.count, 7, "Holding or reversing within the pull cannot buzz repeatedly")
            scroll.testPan.setTranslation(CGPoint(x: 0, y: 240), in: scroll.window)
            scroll.contentOffset.y = 760
            XCTAssertEqual(events.last, .pop)
            XCTAssertEqual(events.count, 8)
            XCTAssertEqual(scroll.contentOffset.y, 976, accuracy: 0.01)
            XCTAssertNil(detent.targetState.target(projected: 1_060, velocity: 0),
                         "A deliberate pop must not be recaptured by the nearby-target rule")
            for pull in [250, 220, 260] {
                scroll.testPan.setTranslation(CGPoint(x: 0, y: CGFloat(pull)), in: scroll.window)
                scroll.contentOffset.y = 1_000 - CGFloat(pull)
            }
            XCTAssertEqual(events.count, 8, "The release remains latched for the entire gesture")
            detent.phaseChanged(to: .decelerating)
            scroll.contentOffset.y = 1_000
            detent.phaseChanged(to: .idle)
            XCTAssertEqual(events.count, 8, "Released motion must not emit a second catch")
            scroll.contentOffset.y = 300
            detent.reduceMotion = true
            detent.scrollToToday()
            XCTAssertEqual(events.count, 8, "Programmatic positioning must stay silent")
        }
    }

    func testMomentumCannotCrossIntoHistoryWithoutBreakingTheSeal() {
        let state = UpcomingScrollTargetState()
        state.update(
            today: 1_000, inset: 80, offset: 1_200, translation: 100,
            drag: UpcomingScrollDetentDrag(start: 1_300, translation: 0, today: 1_000), enabled: true
        )
        state.begin()
        XCTAssertEqual(state.target(projected: 300, velocity: -2_500), 1_080,
                       "A fast flick released before Today must land there rather than bypass the pull")
    }

    @MainActor
    func testOffsetObservationResistsAndReversesWithoutTakingTheNativeDelegate() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let scroll = DetentTestScrollView(frame: window.bounds)
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.contentSize = CGSize(width: 390, height: 3_000)
        scroll.contentInset.top = 80
        window.addSubview(scroll)
        let anchor = UIView(frame: CGRect(x: 0, y: 1_080, width: 390, height: 300))
        scroll.addSubview(anchor)
        let previous = DetentTestDelegate()
        scroll.delegate = previous
        let detent = UpcomingScrollDetent()
        detent.setAnchor(anchor)
        detent.attach(to: scroll)
        var events: [TouchFeedback.Event] = []
        detent.onFeedback = { events.append($0) }
        XCTAssertEqual(detent.todayOffset, 1_000)
        XCTAssertTrue(scroll.delegate === previous)

        scroll.contentOffset.y = 1_000
        detent.phaseChanged(to: .tracking)
        detent.phaseChanged(to: .interacting)
        scroll.testPan.setTranslation(CGPoint(x: 0, y: 40), in: window)
        scroll.contentOffset.y = 960
        XCTAssertGreaterThan(scroll.contentOffset.y, 985)
        XCTAssertEqual(events.count, 1)
        scroll.testPan.setTranslation(CGPoint(x: 0, y: -20), in: window)
        scroll.contentOffset.y += 60
        XCTAssertEqual(scroll.contentOffset.y, 1_020, "Reversing must not retain the resistance displacement")
        XCTAssertEqual(events.count, 1, "Moving into the future does not emit tension")
        scroll.testPan.setTranslation(CGPoint(x: 0, y: 40), in: window)
        scroll.contentOffset.y -= 60
        XCTAssertGreaterThan(scroll.contentOffset.y, 985)
        XCTAssertEqual(events.count, 2, "Returning fully to Today rearms the next pull")
        XCTAssertEqual(events.first, events.last)
        XCTAssertGreaterThan(previous.scrolls, 0)
        XCTAssertTrue(scroll.delegate === previous)
        XCTAssertEqual(scroll.delegate?.scrollViewShouldScrollToTop?(scroll), false)

        detent.cancelInteraction()
        scroll.testPan.setTranslation(CGPoint(x: 0, y: 300), in: window)
        scroll.contentOffset.y = 300
        XCTAssertEqual(scroll.contentOffset.y, 300, "Calendar navigation must bypass the detent")
        XCTAssertEqual(events.count, 2, "Cancelled pulls cannot emit a late pop")
        detent.detach()
        scroll.contentOffset.y = 1_000
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(scroll.delegate === previous)
        XCTAssertNil(detent.todayOffset)
    }

    @MainActor
    func testOuterBounceAndRecycledDateAnchorsRemainNative() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let scroll = DetentTestScrollView(frame: window.bounds)
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.contentSize = CGSize(width: 390, height: 3_000)
        window.addSubview(scroll)
        let anchor = UIView(frame: CGRect(x: 0, y: 1_000, width: 390, height: 300))
        scroll.addSubview(anchor)
        let detent = UpcomingScrollDetent()
        detent.setAnchor(anchor)
        detent.attach(to: scroll)
        defer { detent.detach() }
        scroll.contentOffset.y = 1_000
        detent.phaseChanged(to: .interacting)
        scroll.testPan.setTranslation(CGPoint(x: 0, y: 1_400), in: window)
        scroll.contentOffset.y = -40
        XCTAssertEqual(scroll.contentOffset.y, -40, "Do not clamp UIKit's outer-edge bounce")
        detent.removeAnchor(anchor)
        XCTAssertNil(detent.todayOffset, "A recycled lazy date must not leave stale snap geometry")
        scroll.contentOffset.y = 980
        detent.phaseChanged(to: .idle)
        XCTAssertEqual(scroll.contentOffset.y, 980)
        anchor.frame.origin.y = 1_010
        detent.setAnchor(anchor)
        XCTAssertEqual(detent.todayOffset, 1_010)
    }

    @MainActor
    func testNativeTargetIncludesInsetsAndFeedbackWaitsForArrival() {
        withDetent { detent, scroll, _ in
            var catches = 0
            detent.onFeedback = { if $0 == .selection { catches += 1 } }
            scroll.contentOffset.y = 700
            detent.phaseChanged(to: .interacting)
            scroll.contentOffset.y = 1_030
            XCTAssertEqual(detent.targetState.target(projected: 1_500, velocity: 600), 1_080)
            XCTAssertEqual(catches, 0, "Selecting a target must not pretend the scroll has arrived")
            detent.phaseChanged(to: .decelerating)
            scroll.contentOffset.y = 1_020
            XCTAssertEqual(catches, 0)
            scroll.contentOffset.y = 1_000
            XCTAssertEqual(catches, 1)
            XCTAssertEqual(detent.targetState.target(projected: 1_500, velocity: 600), 1_080)
            scroll.contentOffset.y = 1_000.5
            detent.phaseChanged(to: .idle)
            XCTAssertEqual(catches, 1, "Repeated layout queries and offset updates cannot rearm feedback")
            scroll.contentOffset.y = 300
            detent.reduceMotion = true
            detent.scrollToToday()
            XCTAssertEqual(scroll.contentOffset.y, 1_000)
            XCTAssertEqual(catches, 1, "Navigation to Today remains silent")
        }
    }

    func testProjectedApproachCatchesButFastFlicksAndAssistiveScrollingDoNot() {
        let cases: [(CGFloat, CGFloat, CGFloat, Bool, CGFloat?)] = [
            (800, 1_100, 600, true, 1_080),
            (1_030, 1_100, 1_500, true, nil),
            (1_030, 1_100, 600, false, nil),
            (800, 900, 600, true, nil)
        ]
        for (offset, projected, velocity, enabled, expected) in cases {
            let state = UpcomingScrollTargetState()
            state.update(today: 1_000, inset: 80, offset: offset, translation: 0, drag: nil, enabled: enabled)
            state.begin()
            XCTAssertEqual(state.target(projected: projected, velocity: velocity), expected)
            XCTAssertFalse(state.consumeArrival())
        }
    }

    @MainActor
    func testNavigationNewTouchDetachAndRelayoutCancelCatchFeedback() {
        let cancellations: [(UpcomingScrollDetent, UIView) -> Void] = [
            { detent, _ in detent.cancelInteraction() },
            { detent, _ in detent.phaseChanged(to: .tracking) },
            { detent, _ in detent.detach() },
            { detent, anchor in
                anchor.frame.origin.y += 10
                detent.updateAnchor()
            }
        ]
        for cancel in cancellations {
            withDetent { detent, scroll, anchor in
                var catches = 0
                detent.onFeedback = { if $0 == .selection { catches += 1 } }
                scroll.contentOffset.y = 700
                detent.phaseChanged(to: .interacting)
                scroll.contentOffset.y = 1_030
                XCTAssertEqual(detent.targetState.target(projected: 1_500, velocity: 600), 1_080)
                detent.phaseChanged(to: .decelerating)
                cancel(detent, anchor)
                scroll.contentOffset.y = 1_000
                detent.phaseChanged(to: .idle)
                XCTAssertEqual(catches, 0)
            }
        }
    }

    @MainActor
    private func withDetent(_ body: (UpcomingScrollDetent, DetentTestScrollView, UIView) throws -> Void) rethrows {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let scroll = DetentTestScrollView(frame: window.bounds)
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.contentInset.top = 80
        scroll.contentSize = CGSize(width: 390, height: 3_000)
        window.addSubview(scroll)
        let anchor = UIView(frame: CGRect(x: 0, y: 1_080, width: 390, height: 300))
        scroll.addSubview(anchor)
        let detent = UpcomingScrollDetent()
        detent.setAnchor(anchor)
        detent.attach(to: scroll)
        defer { detent.detach() }
        try body(detent, scroll, anchor)
    }
}

@MainActor
private final class DetentTestScrollView: UIScrollView {
    let testPan = DetentTestPan()
    override var panGestureRecognizer: UIPanGestureRecognizer { testPan }
}

@MainActor
private final class DetentTestPan: UIPanGestureRecognizer {
    private var testTranslation = CGPoint.zero
    override func translation(in view: UIView?) -> CGPoint { testTranslation }
    override func setTranslation(_ translation: CGPoint, in view: UIView?) { testTranslation = translation }
}

@MainActor
private final class DetentTestDelegate: NSObject, UIScrollViewDelegate {
    var scrolls = 0
    func scrollViewDidScroll(_ scrollView: UIScrollView) { scrolls += 1 }
    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool { false }
}
#endif
