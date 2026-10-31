#if os(tvOS)
import CoreUI
import SwiftUI
import UIKit
import XCTest
@testable import FeatureHome

@MainActor
final class HeroShowcaseStageTests: XCTestCase {
    func testScrollAndCrossfadeStartWhenTheTransactionIsSubmitted() throws {
        let stage = HeroShowcaseStage.Controller(
            state: HeroShowcaseState(), hero: AnyView(Color.clear),
            showcase: AnyView(Color.clear), rows: AnyView(Color.clear)
        )
        stage.loadViewIfNeeded()
        stage.updatePeek(firstRowHeight: 300)
        CATransaction.begin()
        defer { stage.stopAnimations(); CATransaction.commit() }
        stage.present(expanded: false, focus: false)
        for host in [stage.hero, stage.showcase, stage.rows] {
            let keys = try XCTUnwrap(host.view.layer.animationKeys())
            XCTAssertFalse(keys.isEmpty)
            for key in keys {
                let animation = try XCTUnwrap(host.view.layer.animation(forKey: key))
                XCTAssertEqual(animation.beginTime, 0, "Cold UI work must not consume the animation before submission.")
                XCTAssertEqual(animation.duration, HeroShowcaseScrollMotion.duration)
                XCTAssertEqual(animation.timingFunction, HeroShowcaseScrollMotion.timingFunction)
            }
        }
    }

    func testForegroundsAndRowsShareOneScrollIncludingRapidReversals() throws {
        let motion = HeroShowcaseScrollMotion()
        let featured = UIView()
        let backdrop = UIView()
        let showcase = UIView()
        let showcaseBackdrop = UIView()
        let rows = UIView()
        motion.bind(featured, to: .featured)
        motion.bind(backdrop, to: .featuredBackdrop)
        motion.bind(showcase, to: .showcase)
        motion.bind(showcaseBackdrop, to: .showcaseBackdrop)
        motion.bind(rows, to: .rows)
        let distance: CGFloat = 320.5
        motion.move(expanded: true, distance: distance, animated: false,
                    reduceMotion: false)
        XCTAssertEqual(featured.transform.ty, 0)
        XCTAssertEqual(showcase.transform.ty + showcaseBackdrop.transform.ty, distance, accuracy: 0.0001)
        XCTAssertEqual(rows.transform.ty, distance)
        var oldKeys: [String] = []
        for expanded in [false, true, false] {
            motion.move(expanded: expanded, distance: distance, animated: true,
                        reduceMotion: false)
            let key = try XCTUnwrap(rows.layer.animationKeys()?.last)
            XCTAssertEqual(featured.transform.ty + backdrop.transform.ty, expanded ? 0 : -distance, accuracy: 0.0001)
            XCTAssertEqual(backdrop.transform.ty, expanded ? 0 : -distance * HeroShowcaseScrollMotion.backdropTravelFraction)
            XCTAssertEqual(backdrop.transform.ty, expanded ? 0 : -120.1875, accuracy: 0.0001)
            XCTAssertEqual(showcaseBackdrop.transform.ty, expanded ? 120.1875 : 0, accuracy: 0.0001)
            XCTAssertEqual(showcase.transform.ty + showcaseBackdrop.transform.ty, rows.transform.ty, accuracy: 0.0001)
            XCTAssertEqual(rows.transform.ty - featured.transform.ty - backdrop.transform.ty, distance, accuracy: 0.0001)
            for (view, fraction) in [(featured, 1 - HeroShowcaseScrollMotion.backdropTravelFraction),
                                     (backdrop, HeroShowcaseScrollMotion.backdropTravelFraction),
                                     (showcase, 1 - HeroShowcaseScrollMotion.backdropTravelFraction),
                                     (showcaseBackdrop, HeroShowcaseScrollMotion.backdropTravelFraction),
                                     (rows, CGFloat(1))] {
                let animation = try XCTUnwrap(view.layer.animation(forKey: key) as? CABasicAnimation)
                XCTAssertEqual(animation.beginTime, 0, "Start at submission, not before focus/layout work.")
                XCTAssertEqual(try XCTUnwrap(animation.fromValue as? CGFloat),
                               (expanded ? -distance : distance) * fraction, accuracy: 0.0001)
                XCTAssertEqual(animation.toValue as? CGFloat, 0)
                XCTAssertTrue(animation.isAdditive)
                XCTAssertEqual(animation.duration, HeroShowcaseScrollMotion.duration)
                XCTAssertEqual(animation.timingFunction, HeroShowcaseScrollMotion.timingFunction)
                for oldKey in oldKeys { XCTAssertNotNil(view.layer.animation(forKey: oldKey)) }
            }
            oldKeys.append(key)
        }
        motion.stopAnimations()
        for view in [featured, backdrop, showcase, showcaseBackdrop, rows] { XCTAssertNil(view.layer.animationKeys()) }
    }

    func testScrollMotionHandlesLateMountsAndReducedMotionWithoutForegroundTravel() {
        let motion = HeroShowcaseScrollMotion()
        motion.move(expanded: true, distance: 300, animated: false,
                    reduceMotion: false)
        let featured = UIView()
        let backdrop = UIView()
        let showcase = UIView()
        let showcaseBackdrop = UIView()
        let rows = UIView()
        motion.bind(featured, to: .featured)
        motion.bind(backdrop, to: .featuredBackdrop)
        motion.bind(showcase, to: .showcase)
        motion.bind(showcaseBackdrop, to: .showcaseBackdrop)
        motion.bind(rows, to: .rows)
        XCTAssertEqual(featured.transform.ty, 0)
        XCTAssertEqual(showcase.transform.ty + showcaseBackdrop.transform.ty, 300, accuracy: 0.0001)
        for expanded in [false, true] {
            motion.move(expanded: expanded, distance: 300, animated: true,
                        reduceMotion: true)
            XCTAssertEqual(featured.transform.ty, 0)
            XCTAssertEqual(backdrop.transform.ty, 0)
            XCTAssertEqual(showcase.transform.ty, 0)
            XCTAssertEqual(showcaseBackdrop.transform.ty, 0)
            XCTAssertEqual(rows.transform.ty, expanded ? 300 : 0)
            for view in [featured, backdrop, showcase, showcaseBackdrop, rows] { XCTAssertNil(view.layer.animationKeys()) }
        }
        motion.unbind(featured, from: .featured)
        motion.move(expanded: false, distance: 300, animated: false,
                    reduceMotion: false)
        XCTAssertEqual(featured.transform.ty, 0)
        let replacement = UIView()
        motion.bind(replacement, to: .featured)
        XCTAssertEqual(replacement.transform.ty + backdrop.transform.ty, -300, accuracy: 0.0001)
    }

    func testReturnChevronCentersOnTheDisplayAndExpiresUntilTheNextArrival() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        let cue = HeroShowcaseReturnCue.CueView()
        root.view.addSubview(cue)
        defer { cue.setActive(false); window.isHidden = true; window.rootViewController = nil }
        cue.frame = CGRect(x: 80, y: 0, width: 1840, height: 1080)
        cue.layoutIfNeeded()
        let frame = cue.arrow.convert(cue.arrow.bounds, to: window)
        XCTAssertEqual(frame.midX, window.bounds.midX, accuracy: 0.5)
        XCTAssertEqual(frame.midY, 72, accuracy: 0.5)
        XCTAssertFalse(cue.isUserInteractionEnabled)
        XCTAssertTrue(cue.accessibilityElementsHidden)
        XCTAssertEqual(cue.arrow.alpha, 0)
        cue.setActive(true)
        XCTAssertEqual(cue.arrow.alpha, 1)
        try await Task.sleep(for: .milliseconds(3400))
        XCTAssertEqual(cue.arrow.alpha, 0)
        cue.setActive(true)
        XCTAssertEqual(cue.arrow.alpha, 0, "Ordinary updates on the same row must not restart the hint")
        cue.setActive(false)
        cue.setActive(true)
        XCTAssertEqual(cue.arrow.alpha, 1)
        cue.top = 132
        cue.layoutIfNeeded()
        XCTAssertEqual(cue.arrow.convert(cue.arrow.bounds, to: window).midY, 132, accuracy: 0.5)
        cue.removeFromSuperview()
        XCTAssertEqual(cue.arrow.alpha, 0)
    }

    func testFeaturedViewportStaysCenteredWithoutChangingTheRowsBreakout() {
        let cases: [(CGRect, CGRect, CGRect)] = [
            (CGRect(x: 0, y: 0, width: 1840, height: 1080),
             CGRect(x: -80, y: 0, width: 1920, height: 1080),
             CGRect(x: 0, y: 0, width: 1760, height: 1080)),
            (CGRect(x: 0, y: 0, width: 1760, height: 1080),
             CGRect(x: -80, y: 0, width: 1920, height: 1080),
             CGRect(x: 0, y: 0, width: 1760, height: 1080)),
            (CGRect(x: 0, y: 0, width: 1840, height: 1080),
             CGRect(x: 0, y: 0, width: 1920, height: 1080),
             CGRect(x: 80, y: 0, width: 1760, height: 1080)),
            (CGRect(x: 0, y: 0, width: 1920, height: 1080),
             CGRect(x: 0, y: 0, width: 1920, height: 1080),
             CGRect(x: 0, y: 0, width: 1920, height: 1080))
        ]
        for (bounds, window, expected) in cases {
            let frame = HeroShowcaseStage.Controller.featuredFrame(in: bounds, window: window)
            XCTAssertEqual(frame, expected)
            XCTAssertEqual(frame.midX, window.midX)
        }
    }

    func testRowsCannotTakeInitialFocusAndBoundaryInputOnlyChangesTheTopEdge() {
        let stage = HeroShowcaseStage.Controller(
            state: HeroShowcaseState(), hero: AnyView(Color.clear),
            showcase: AnyView(Color.clear), rows: AnyView(Color.clear)
        )
        stage.loadViewIfNeeded()
        let hero = StageVirtualFocusItem(parent: stage.hero.view)
        let row = StageVirtualFocusItem(parent: stage.rows.view)
        XCTAssertFalse(stage.rows.view.isUserInteractionEnabled)
        XCTAssertTrue(stage.rows.view.accessibilityElementsHidden)
        XCTAssertEqual(stage.boundaryDestination(for: .down, from: hero), false)
        XCTAssertNil(stage.boundaryDestination(for: .up, from: hero))
        XCTAssertNil(stage.boundaryDestination(for: .down, from: row))
        stage.canEnterRows = { false }
        XCTAssertNil(stage.boundaryDestination(for: .down, from: hero))
        stage.present(expanded: false, focus: false)
        XCTAssertTrue(stage.rows.view.isUserInteractionEnabled)
        XCTAssertFalse(stage.rows.view.accessibilityElementsHidden)
        XCTAssertEqual(stage.boundaryDestination(for: .up, from: row), true)
        XCTAssertNil(stage.boundaryDestination(for: .down, from: row))
        XCTAssertNil(stage.boundaryDestination(for: .left, from: row))
        stage.canReturn = { false }
        XCTAssertNil(stage.boundaryDestination(for: .up, from: row))
        stage.stopAnimations()
    }

    func testMountedPinnedViewportKeepsLeadingContentAndRowBoundsDuringTransitions() {
        let stage = HeroShowcaseStage.Controller(
            state: HeroShowcaseState(), hero: AnyView(Color.clear),
            showcase: AnyView(Color.clear), rows: AnyView(Color.clear)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        defer { stage.stopAnimations(); window.isHidden = true; window.rootViewController = nil }
        root.addChild(stage)
        root.view.addSubview(stage.view)
        stage.didMove(toParent: root)
        for width: CGFloat in [1840, 1760] {
            stage.view.frame = CGRect(x: 80, y: 0, width: width, height: 1080)
            for expanded in [true, false, true] {
                stage.present(expanded: expanded, focus: false)
                stage.viewDidLayoutSubviews()
                let hero = stage.hero.view.convert(stage.hero.view.bounds, to: window)
                XCTAssertEqual(hero.minX, 80, accuracy: 0.5)
                XCTAssertEqual(hero.midX, window.bounds.midX, accuracy: 0.5)
                XCTAssertEqual(hero.width, 1760, accuracy: 0.5)
                let showcase = stage.showcase.view.convert(stage.showcase.view.bounds, to: window)
                XCTAssertEqual(showcase.minX, 80, accuracy: 0.5)
                XCTAssertEqual(showcase.maxX, window.bounds.maxX, accuracy: 0.5)
                XCTAssertEqual(stage.rows.view.bounds, stage.view.bounds)
                XCTAssertEqual(stage.rows.view.center.x, stage.view.bounds.midX, accuracy: 0.5)
            }
        }
    }

    func testEveryLayerFillsTheViewportBeforeAndAfterContentUpdates() {
        let content = AnyView(Color.clear.frame(width: 80, height: 40))
        let stage = HeroShowcaseStage.Controller(
            state: HeroShowcaseState(), hero: content, showcase: content, rows: content
        )
        let viewport = CGSize(width: 1920, height: 1080)
        for _ in 0..<2 {
            for host in [stage.hero, stage.showcase, stage.rows] {
                XCTAssertEqual(host.sizeThatFits(in: viewport), viewport)
            }
            stage.updateContent(hero: content, showcase: content, rows: content)
        }
    }

    func testSmallHostedContentStaysAtTheTopLeadingOrigin() async {
        let marker = UIView()
        let mounted = expectation(description: "Showcase content mounted")
        let stage = HeroShowcaseStage.Controller(
            state: HeroShowcaseState(), hero: AnyView(Color.clear),
            showcase: AnyView(StageLayoutMarker(view: marker, onMount: { mounted.fulfill() })
                .frame(width: 80, height: 40)),
            rows: AnyView(Color.clear)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        window.rootViewController = stage
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        stage.present(expanded: false, focus: false)
        stage.view.frame = window.bounds
        stage.viewDidLayoutSubviews()
        await fulfillment(of: [mounted], timeout: 2)
        stage.showcase.view.layoutIfNeeded()
        XCTAssertNotNil(marker.superview)
        let frame = marker.convert(marker.bounds, to: stage.showcase.view)
        XCTAssertEqual(frame.origin.x, 0, accuracy: 0.5)
        XCTAssertEqual(frame.origin.y, 0, accuracy: 0.5)
        XCTAssertEqual(frame.size, CGSize(width: 80, height: 40))
    }

    func testFocusOwnershipIncludesVirtualItemsAndNestedNativeControllers() {
        let stage = HeroShowcaseStage.Controller(
            state: HeroShowcaseState(), hero: AnyView(Color.clear),
            showcase: AnyView(Color.clear), rows: AnyView(Color.clear)
        )
        stage.loadViewIfNeeded()
        let heroItem = StageVirtualFocusItem(parent: stage.hero.view)
        let rowItem = StageVirtualFocusItem(parent: stage.rows.view)
        let nested = UIViewController()
        stage.rows.addChild(nested)
        stage.rows.view.addSubview(nested.view)
        nested.didMove(toParent: stage.rows)
        let nativeButton = UIButton()
        nested.view.addSubview(nativeButton)
        let nestedItem = StageVirtualFocusItem(parent: nested.view)
        XCTAssertTrue(stage.contains(heroItem, in: stage.hero))
        XCTAssertFalse(stage.contains(heroItem, in: stage.rows))
        XCTAssertTrue(stage.contains(rowItem, in: stage.rows))
        XCTAssertFalse(stage.contains(rowItem, in: stage.hero))
        XCTAssertTrue(stage.contains(nestedItem, in: stage.rows))
        XCTAssertTrue(stage.contains(nativeButton, in: stage.rows))
        XCTAssertFalse(stage.contains(StageVirtualFocusItem(parent: UIView()), in: stage.hero))
        XCTAssertFalse(stage.contains(nil, in: stage.hero))
    }

    func testTransitionKeepsTheSameNativeHostsAndFocusDestinations() {
        let state = HeroShowcaseState()
        let stage = HeroShowcaseStage.Controller(
            state: state,
            hero: AnyView(Button("Play") {}),
            showcase: AnyView(Text("Details")),
            rows: AnyView(Button("First card") {})
        )
        stage.loadViewIfNeeded()
        stage.updatePeek(firstRowHeight: 320)
        let hero = stage.hero
        let rows = stage.rows
        for _ in 0..<4 {
            stage.present(expanded: false, focus: false)
            XCTAssertFalse(state.isExpanded)
            XCTAssertTrue(stage.hero.view.accessibilityElementsHidden)
            XCTAssertFalse(stage.showcase.view.accessibilityElementsHidden)
            XCTAssertFalse(stage.hero.view.isUserInteractionEnabled)
            XCTAssertTrue(stage.preferredFocusEnvironments.first === rows)
            XCTAssertEqual(stage.rows.view.transform.ty, 0, accuracy: 0.01)
            stage.present(expanded: true, focus: false)
            XCTAssertTrue(state.isExpanded)
            XCTAssertTrue(stage.preferredFocusEnvironments.first === hero)
            XCTAssertTrue(stage.hero === hero)
            XCTAssertTrue(stage.rows === rows)
            XCTAssertTrue(stage.hero.view.isUserInteractionEnabled)
        }
        stage.stopAnimations()
    }

    func testPeekUsesTheFirstRowsMeasuredHeightWithoutResizingItsHost() {
        let stage = HeroShowcaseStage.Controller(
            state: HeroShowcaseState(), hero: AnyView(Color.clear),
            showcase: AnyView(Color.clear), rows: AnyView(Color.clear)
        )
        stage.loadViewIfNeeded()
        stage.view.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        stage.viewDidLayoutSubviews()
        let bounds = stage.rows.view.bounds
        for height: CGFloat in [260, 420, 300] {
            stage.updatePeek(firstRowHeight: height)
            let originalTop = FocusHeroLayout.rowsBottom(rowSpacing: FocusHeroLayout.rowSpacing) - height
            XCTAssertEqual(originalTop + stage.rows.view.transform.ty,
                           HomeHeroLayout.screenHeight - HomeHeroLayout.rowOverlap, accuracy: 0.01)
            XCTAssertEqual(stage.rows.view.bounds, bounds)
        }
    }

    func testRapidReversalRetainsTheInFlightAdditiveMotion() throws {
        let stage = HeroShowcaseStage.Controller(
            state: HeroShowcaseState(), hero: AnyView(Color.clear),
            showcase: AnyView(Color.clear), rows: AnyView(Color.clear)
        )
        stage.loadViewIfNeeded()
        stage.updatePeek(firstRowHeight: 300)
        stage.present(expanded: false, focus: false)
        let layer = stage.rows.view.layer
        let firstKey = try XCTUnwrap(layer.animationKeys()?.first)
        let first = try XCTUnwrap(layer.animation(forKey: firstKey) as? CABasicAnimation)
        stage.present(expanded: true, focus: false)
        XCTAssertNotNil(layer.animation(forKey: firstKey))
        let keys = try XCTUnwrap(layer.animationKeys())
        XCTAssertEqual(keys.count, 2)
        XCTAssertTrue(first.isAdditive)
        for key in keys {
            let animation = try XCTUnwrap(layer.animation(forKey: key) as? CABasicAnimation)
            XCTAssertTrue(animation.isAdditive)
            XCTAssertEqual(animation.keyPath, "transform.translation.y")
            XCTAssertEqual(animation.duration, HeroShowcaseScrollMotion.duration)
        }
        stage.stopAnimations()
        XCTAssertTrue(layer.animationKeys()?.isEmpty ?? true)
    }
}

private struct StageLayoutMarker: UIViewRepresentable {
    let view: UIView
    let onMount: () -> Void
    func makeUIView(context: Context) -> UIView {
        onMount()
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

@MainActor
private final class StageVirtualFocusItem: NSObject, UIFocusItem {
    weak var parentFocusEnvironment: (any UIFocusEnvironment)?
    var frame: CGRect { CGRect(x: 80, y: 200, width: 160, height: 50) }
    var preferredFocusEnvironments: [any UIFocusEnvironment] { [] }
    var focusItemContainer: (any UIFocusItemContainer)? { nil }
    var canBecomeFocused: Bool { true }

    init(parent: any UIFocusEnvironment) { parentFocusEnvironment = parent }
    func setNeedsFocusUpdate() {}
    func updateFocusIfNeeded() {}
    func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool { true }
    func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {}
}
#endif
