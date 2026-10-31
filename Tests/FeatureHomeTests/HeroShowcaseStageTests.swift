#if os(tvOS)
import CoreUI
import SwiftUI
import UIKit
import XCTest
@testable import FeatureHome

@MainActor
final class HeroShowcaseStageTests: XCTestCase {
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

    func testRapidReversalRetainsTheInFlightAdditiveSpring() throws {
        let stage = HeroShowcaseStage.Controller(
            state: HeroShowcaseState(), hero: AnyView(Color.clear),
            showcase: AnyView(Color.clear), rows: AnyView(Color.clear)
        )
        stage.loadViewIfNeeded()
        stage.updatePeek(firstRowHeight: 300)
        stage.present(expanded: false, focus: false)
        let layer = stage.rows.view.layer
        let firstKey = try XCTUnwrap(layer.animationKeys()?.first)
        let first = try XCTUnwrap(layer.animation(forKey: firstKey) as? CASpringAnimation)
        stage.present(expanded: true, focus: false)
        XCTAssertNotNil(layer.animation(forKey: firstKey))
        let keys = try XCTUnwrap(layer.animationKeys())
        XCTAssertEqual(keys.count, 2)
        XCTAssertTrue(first.isAdditive)
        for key in keys {
            let animation = try XCTUnwrap(layer.animation(forKey: key) as? CASpringAnimation)
            XCTAssertTrue(animation.isAdditive)
            XCTAssertEqual(animation.keyPath, "transform.translation.y")
            XCTAssertEqual(animation.duration, FocusHeroLayout.rowSpring.settlingDuration)
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
