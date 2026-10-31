#if os(tvOS)
import CoreUI
import SwiftUI
import UIKit
import XCTest
@testable import FeatureHome

@MainActor
final class HeroShowcaseStageTests: XCTestCase {
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
#endif
