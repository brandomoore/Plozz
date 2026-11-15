#if os(iOS)
@testable import FeatureHomeCore
import UIKit
import XCTest

final class UpcomingScrollDetentTests: XCTestCase {
    func testPastRequiresADeliberatePullButFutureScrollingIsUnchanged() {
        let drag = UpcomingScrollDetentDrag(start: 1_000, translation: 0, today: 1_000)
        XCTAssertGreaterThan(drag.offset(translation: 40), 985)
        XCTAssertLessThan(drag.offset(translation: 40), 1_000)
        XCTAssertEqual(drag.target(proposed: 400, translation: 40), 1_000)
        XCTAssertEqual(drag.offset(translation: -80), 1_080)
        XCTAssertEqual(drag.target(proposed: 1_300, translation: -80), 1_300)
        XCTAssertEqual(drag.offset(translation: 180), 865)
        XCTAssertEqual(drag.target(proposed: 600, translation: 180), 600)
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

    func testOnlyNearbyLandingsSnapAndHistoryIsNotTrapped() {
        let history = UpcomingScrollDetentDrag(start: 700, translation: 0, today: 1_000)
        XCTAssertEqual(history.offset(translation: 80), 620)
        XCTAssertEqual(history.target(proposed: 970, translation: -250), 1_000)
        XCTAssertEqual(history.target(proposed: 1_035, translation: -300), 1_000)
        XCTAssertEqual(history.target(proposed: 850, translation: -100), 850)
        XCTAssertEqual(history.target(proposed: 1_400, translation: -400), 1_400)
        let future = UpcomingScrollDetentDrag(start: 1_300, translation: 0, today: 1_000)
        XCTAssertEqual(future.target(proposed: 600, translation: 100), 600,
                       "A far fling must not be caught just because it passes Today")
        XCTAssertEqual(future.target(proposed: 970, translation: 100), 1_000)
        XCTAssertEqual(future.target(proposed: 600, translation: 450), 600)
    }

    @MainActor
    func testNativeAdapterPreservesProgrammaticNavigationAndRestoresDelegate() {
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
        XCTAssertTrue(scroll.delegate === detent)

        scroll.contentOffset.y = 1_000
        detent.scrollViewWillBeginDragging(scroll)
        scroll.testDragging = true
        scroll.testPan.setTranslation(CGPoint(x: 0, y: 40), in: window)
        scroll.contentOffset.y = 960
        detent.scrollViewDidScroll(scroll)
        XCTAssertGreaterThan(scroll.contentOffset.y, 985)
        scroll.testPan.setTranslation(CGPoint(x: 0, y: -20), in: window)
        scroll.contentOffset.y += 60
        detent.scrollViewDidScroll(scroll)
        XCTAssertEqual(scroll.contentOffset.y, 1_020, "Reversing must not retain the resistance displacement")
        scroll.testPan.setTranslation(CGPoint(x: 0, y: 40), in: window)
        scroll.contentOffset.y -= 60
        detent.scrollViewDidScroll(scroll)
        var target = CGPoint(x: 0, y: 400)
        detent.scrollViewWillEndDragging(scroll, withVelocity: CGPoint(x: 0, y: -2), targetContentOffset: &target)
        XCTAssertEqual(target.y, 1_000)
        XCTAssertEqual(previous.begins, 1)
        XCTAssertEqual(previous.ends, 1)
        XCTAssertGreaterThan(previous.scrolls, 0)
        let forwarded: UIScrollViewDelegate = detent
        XCTAssertEqual(forwarded.scrollViewShouldScrollToTop?(scroll), false)

        scroll.testDragging = false
        detent.scrollViewDidEndDragging(scroll, willDecelerate: true)
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
        detent.scrollViewWillBeginDragging(scroll)
        scroll.testDragging = true
        scroll.testPan.setTranslation(CGPoint(x: 0, y: 1_200), in: window)
        scroll.contentOffset.y = -40
        detent.scrollViewDidScroll(scroll)
        XCTAssertEqual(scroll.contentOffset.y, -40, "Do not clamp UIKit's outer-edge bounce")
        detent.removeAnchor(anchor)
        XCTAssertNil(detent.todayOffset, "A recycled lazy date must not leave stale snap geometry")
        var target = CGPoint(x: 0, y: 980)
        detent.scrollViewWillEndDragging(scroll, withVelocity: .zero, targetContentOffset: &target)
        XCTAssertEqual(target.y, 980)
        anchor.frame.origin.y = 1_010
        detent.setAnchor(anchor)
        detent.scrollViewWillEndDragging(scroll, withVelocity: .zero, targetContentOffset: &target)
        XCTAssertEqual(target.y, 1_010, "Returning near a remounted Today uses its new geometry")
    }

    @MainActor
    func testReducedMotionSettlesWithoutAnAnimatedScroll() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let scroll = DetentTestScrollView(frame: window.bounds)
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.contentSize = CGSize(width: 390, height: 3_000)
        window.addSubview(scroll)
        let anchor = UIView(frame: CGRect(x: 0, y: 1_000, width: 390, height: 300))
        scroll.addSubview(anchor)
        let detent = UpcomingScrollDetent()
        detent.reduceMotion = true
        detent.setAnchor(anchor)
        detent.attach(to: scroll)
        defer { detent.detach() }
        scroll.contentOffset.y = 1_000
        detent.scrollViewWillBeginDragging(scroll)
        scroll.testPan.setTranslation(CGPoint(x: 0, y: 40), in: window)
        scroll.contentOffset.y = 960
        var target = CGPoint(x: 0, y: 960)
        detent.scrollViewWillEndDragging(scroll, withVelocity: .zero, targetContentOffset: &target)
        detent.scrollViewDidEndDragging(scroll, willDecelerate: false)
        XCTAssertEqual(scroll.contentOffset.y, 1_000)
        XCTAssertEqual(scroll.lastAnimated, false)
    }
}

@MainActor
private final class DetentTestScrollView: UIScrollView {
    let testPan = DetentTestPan()
    var testDragging = false
    var lastAnimated: Bool?
    override var isDragging: Bool { testDragging }
    override var panGestureRecognizer: UIPanGestureRecognizer { testPan }

    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        lastAnimated = animated
        super.setContentOffset(contentOffset, animated: animated)
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
    var begins = 0
    var ends = 0
    var scrolls = 0
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { begins += 1 }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { scrolls += 1 }
    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView, withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) { ends += 1 }
    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool { false }
}
#endif
