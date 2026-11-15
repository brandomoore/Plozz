#if os(iOS)
@testable import FeatureHomeCore
import UIKit
import XCTest

final class UpcomingScrollDetentTests: XCTestCase {
    func testPastRequiresADeliberatePullButFutureScrollingIsUnchanged() {
        let drag = UpcomingScrollDetentDrag(start: 1_000, translation: 0, today: 1_000)
        XCTAssertGreaterThan(drag.offset(translation: 40), 985)
        XCTAssertLessThan(drag.offset(translation: 40), 1_000)
        XCTAssertTrue(drag.shouldSnap(offset: 987, translation: 40, velocity: -600))
        XCTAssertEqual(drag.offset(translation: -80), 1_080)
        XCTAssertFalse(drag.shouldSnap(offset: 1_080, translation: -80, velocity: 600))
        XCTAssertEqual(drag.offset(translation: 180), 865)
        XCTAssertFalse(drag.shouldSnap(offset: 865, translation: 180, velocity: -600))
    }

    func testResistanceIsContinuousAndRegainsFingerSpeed() {
        let drag = UpcomingScrollDetentDrag(start: 1_000, translation: 0, today: 1_000)
        var previous = drag.offset(translation: 0)
        for pull in 1...240 {
            let next = drag.offset(translation: CGFloat(pull))
            XCTAssertGreaterThan(previous - next, 0)
            XCTAssertLessThanOrEqual(previous - next, 1.001)
            previous = next
        }
        XCTAssertEqual(drag.offset(translation: 120), 925, accuracy: 0.001)
        XCTAssertEqual(drag.offset(translation: 121), 924, accuracy: 0.001)
    }

    func testOnlyNearbyReleasesSnapAndHistoryIsNotTrapped() {
        let history = UpcomingScrollDetentDrag(start: 700, translation: 0, today: 1_000)
        XCTAssertEqual(history.offset(translation: 80), 620)
        XCTAssertTrue(history.shouldSnap(offset: 970, translation: -270, velocity: 600))
        XCTAssertTrue(history.shouldSnap(offset: 1_035, translation: -335, velocity: -600))
        XCTAssertFalse(history.shouldSnap(offset: 850, translation: -150, velocity: 0))
        XCTAssertFalse(history.shouldSnap(offset: 1_035, translation: -335, velocity: 2_000))
        let future = UpcomingScrollDetentDrag(start: 1_300, translation: 0, today: 1_000)
        XCTAssertFalse(future.shouldSnap(offset: 1_200, translation: 100, velocity: -2_000))
        XCTAssertTrue(future.shouldSnap(offset: 1_030, translation: 270, velocity: -600))
        XCTAssertFalse(future.shouldSnap(offset: 895, translation: 450, velocity: -600))
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
        XCTAssertEqual(detent.todayOffset, 1_000)
        XCTAssertTrue(scroll.delegate === previous)

        scroll.contentOffset.y = 1_000
        detent.phaseChanged(from: .idle, to: .tracking, velocity: 0)
        detent.phaseChanged(from: .tracking, to: .interacting, velocity: 0)
        scroll.testPan.setTranslation(CGPoint(x: 0, y: 40), in: window)
        scroll.contentOffset.y = 960
        XCTAssertGreaterThan(scroll.contentOffset.y, 985)
        scroll.testPan.setTranslation(CGPoint(x: 0, y: -20), in: window)
        scroll.contentOffset.y += 60
        XCTAssertEqual(scroll.contentOffset.y, 1_020, "Reversing must not retain the resistance displacement")
        scroll.testPan.setTranslation(CGPoint(x: 0, y: 40), in: window)
        scroll.contentOffset.y -= 60
        XCTAssertGreaterThan(scroll.contentOffset.y, 985)
        XCTAssertGreaterThan(previous.scrolls, 0)
        XCTAssertTrue(scroll.delegate === previous)
        XCTAssertEqual(scroll.delegate?.scrollViewShouldScrollToTop?(scroll), false)

        detent.cancelInteraction()
        scroll.contentOffset.y = 300
        XCTAssertEqual(scroll.contentOffset.y, 300, "Calendar navigation must bypass the detent")
        detent.detach()
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
        detent.phaseChanged(from: .idle, to: .interacting, velocity: 0)
        scroll.testPan.setTranslation(CGPoint(x: 0, y: 1_200), in: window)
        scroll.contentOffset.y = -40
        XCTAssertEqual(scroll.contentOffset.y, -40, "Do not clamp UIKit's outer-edge bounce")
        detent.removeAnchor(anchor)
        XCTAssertNil(detent.todayOffset, "A recycled lazy date must not leave stale snap geometry")
        scroll.contentOffset.y = 980
        detent.phaseChanged(from: .interacting, to: .idle, velocity: 0)
        XCTAssertEqual(scroll.contentOffset.y, 980)
        anchor.frame.origin.y = 1_010
        detent.setAnchor(anchor)
        XCTAssertEqual(detent.todayOffset, 1_010)
    }

    @MainActor
    func testReleaseNearTodaySettlesWithMomentumAndHonorsReducedMotion() async {
        await verifySettle(reduceMotion: false)
        await verifySettle(reduceMotion: true)
    }

    @MainActor
    func testDecelerationEndingNearTodaySettlesEvenWhenReleaseWasFarAway() async {
        await verifySettle(reduceMotion: false, deceleratesIntoRange: true)
    }

    @MainActor
    private func verifySettle(reduceMotion: Bool, deceleratesIntoRange: Bool = false) async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let scroll = DetentTestScrollView(frame: window.bounds)
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.contentSize = CGSize(width: 390, height: 3_000)
        window.addSubview(scroll)
        let anchor = UIView(frame: CGRect(x: 0, y: 1_000, width: 390, height: 300))
        scroll.addSubview(anchor)
        let detent = UpcomingScrollDetent()
        detent.reduceMotion = reduceMotion
        detent.setAnchor(anchor)
        detent.attach(to: scroll)
        defer { detent.detach() }
        scroll.contentOffset.y = 700
        detent.phaseChanged(from: .idle, to: .interacting, velocity: 0)
        if deceleratesIntoRange {
            scroll.contentOffset.y = 800
            detent.phaseChanged(from: .interacting, to: .decelerating, velocity: 600)
            XCTAssertNil(scroll.lastAnimated, "A distant release must retain natural momentum")
        }
        scroll.testPan.setTranslation(CGPoint(x: 0, y: -330), in: window)
        scroll.contentOffset.y = 1_030
        let settled = expectation(description: "Native settle requested")
        scroll.onSetOffset = { point, animated in
            if point.y == 1_000 {
                XCTAssertEqual(animated, !reduceMotion)
                settled.fulfill()
            }
        }
        if deceleratesIntoRange {
            detent.phaseChanged(from: .decelerating, to: .idle, velocity: 0)
        } else {
            detent.phaseChanged(from: .interacting, to: .decelerating, velocity: 600)
        }
        XCTAssertEqual(scroll.lastAnimated, false, "Momentum must stop before the settle starts")
        await fulfillment(of: [settled], timeout: 1)
        if reduceMotion { XCTAssertEqual(scroll.contentOffset.y, 1_000) }
        XCTAssertEqual(scroll.lastAnimated, !reduceMotion)
    }

    @MainActor
    func testCalendarNavigationNewTouchAndDetachCancelPendingSettles() async {
        await verifyCancelledSettle { $0.cancelInteraction() }
        await verifyCancelledSettle { $0.phaseChanged(from: .decelerating, to: .tracking, velocity: 0) }
        await verifyCancelledSettle { $0.detach() }
    }

    @MainActor
    private func verifyCancelledSettle(_ cancel: (UpcomingScrollDetent) -> Void) async {
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
        scroll.contentOffset.y = 1_020
        detent.phaseChanged(from: .idle, to: .interacting, velocity: 0)
        detent.phaseChanged(from: .interacting, to: .idle, velocity: 0)
        cancel(detent)
        scroll.contentOffset.y = 300
        let noSettle = expectation(description: "Cancelled navigation must not snap")
        noSettle.isInverted = true
        scroll.onSetOffset = { _, _ in noSettle.fulfill() }
        await fulfillment(of: [noSettle], timeout: 0.1)
        XCTAssertEqual(scroll.contentOffset.y, 300)
    }
}

@MainActor
private final class DetentTestScrollView: UIScrollView {
    let testPan = DetentTestPan()
    var lastAnimated: Bool?
    var onSetOffset: ((CGPoint, Bool) -> Void)?
    override var panGestureRecognizer: UIPanGestureRecognizer { testPan }

    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        lastAnimated = animated
        super.setContentOffset(contentOffset, animated: animated)
        onSetOffset?(contentOffset, animated)
    }
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
