#if os(tvOS)
import CoreModels
@testable import CoreUI
import HeroUI
import SwiftUI
import UIKit
import XCTest
@testable import FeatureHome

@MainActor
final class HeroShowcaseStageTests: XCTestCase {
    func testNativeScrollOriginCanFollowAnAlreadyAdmittedStage() {
        let state = HeroShowcaseState()
        state.setExpanded(false, deferNativeRows: true)
        XCTAssertFalse(state.isExpanded)
        XCTAssertTrue(state.nativeRowsExpanded)
        state.synchronizeNativeRows()
        XCTAssertFalse(state.nativeRowsExpanded)
        state.setExpanded(true)
        XCTAssertTrue(state.isExpanded)
        XCTAssertTrue(state.nativeRowsExpanded)
    }

    func testNativeScrollOriginSynchronizationUsesTheLatestDestination() {
        let state = HeroShowcaseState()
        state.setExpanded(false, deferNativeRows: true)
        state.setExpanded(true, deferNativeRows: true)
        state.synchronizeNativeRows()
        XCTAssertTrue(state.nativeRowsExpanded)
    }

    func testContentOriginRebasesScrollWithoutRestartingViewportMotion() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        let scroll = UIScrollView(frame: window.bounds)
        scroll.contentSize = CGSize(width: 1920, height: 3000)
        root.view.addSubview(scroll)
        let mask = UIView(frame: window.bounds)
        root.view.addSubview(mask)
        let motion = FocusHeroRowMotion()
        motion.mask = mask
        motion.height = 300
        motion.heightStops = [.init(offset: 0, height: 300), .init(offset: 500, height: 460)]
        let position = FocusHeroNativeScrollPosition.PositionView()
        position.rowMotion = motion
        scroll.addSubview(position)
        defer {
            position.stop()
            window.isHidden = true
            window.rootViewController = nil
        }
        CATransaction.begin()
        defer { CATransaction.commit() }
        position.move(to: 500, rowID: "second", contentOrigin: 320.5)
        position.move(to: 0, rowID: "first", contentOrigin: 0)
        let key = try XCTUnwrap(scroll.layer.animationKeys()?.first)
        let original = try XCTUnwrap(scroll.layer.animation(forKey: key) as? CASpringAnimation)
        XCTAssertEqual(original.fromValue as? CGFloat, 500, "An origin change is not extra row travel.")
        let heightKey = try XCTUnwrap(mask.layer.animationKeys()?.first)
        let heightPath = try XCTUnwrap(mask.layer.animation(forKey: heightKey) as? CAKeyframeAnimation)
        for origin: CGFloat in [320.5, 0, 640.25] {
            position.move(to: 0, rowID: "first", contentOrigin: origin)
            XCTAssertEqual(scroll.contentOffset.y, origin, accuracy: 0.5)
            XCTAssertEqual(scroll.layer.animationKeys(), [key])
            let retained = try XCTUnwrap(scroll.layer.animation(forKey: key) as? CASpringAnimation)
            XCTAssertEqual(retained.fromValue as? CGFloat, 500)
            XCTAssertEqual(retained.beginTime, original.beginTime)
            XCTAssertEqual(mask.layer.animationKeys(), [heightKey])
            let retainedPath = try XCTUnwrap(mask.layer.animation(forKey: heightKey) as? CAKeyframeAnimation)
            XCTAssertEqual(retainedPath.values as? [CGFloat], heightPath.values as? [CGFloat])
            XCTAssertEqual(retainedPath.beginTime, heightPath.beginTime)
        }
        position.move(to: 250, rowID: "second", contentOrigin: 0)
        let nextKey = try XCTUnwrap(scroll.layer.animationKeys()?.first { $0 != key })
        let next = try XCTUnwrap(scroll.layer.animation(forKey: nextKey) as? CASpringAnimation)
        XCTAssertEqual(next.fromValue as? CGFloat, -250)
        XCTAssertNotNil(scroll.layer.animation(forKey: key))
    }

    func testRecreatedStageRestoresItsRetainedCollapsedPresentation() {
        let state = HeroShowcaseState()
        state.setExpanded(false)
        let stage = HeroShowcaseStage.Controller(
            state: state, hero: AnyView(Button("Hero") {}),
            showcase: AnyView(Text("Showcase")), rows: AnyView(Button("Row") {})
        )
        stage.loadViewIfNeeded()
        defer { stage.stopAnimations() }
        XCTAssertEqual(stage.hero.view.alpha, 0)
        XCTAssertFalse(stage.hero.view.isUserInteractionEnabled)
        XCTAssertTrue(stage.hero.view.accessibilityElementsHidden)
        XCTAssertEqual(stage.showcase.view.alpha, 1)
        XCTAssertFalse(stage.showcase.view.accessibilityElementsHidden)
        XCTAssertTrue(stage.rows.view.isUserInteractionEnabled)
        XCTAssertFalse(stage.rows.view.accessibilityElementsHidden)
        XCTAssertTrue(stage.preferredFocusEnvironments.first === stage.rows)
    }

    func testHeroMountedWhileSuspendedResumesAutoAdvanceOnReturn() async throws {
        try await assertSuspendedHeroResumes(addSecondItemAfterMount: false)
    }

    func testHeroBecomingPageableWhileSuspendedResumesAutoAdvanceOnReturn() async throws {
        try await assertSuspendedHeroResumes(addSecondItemAfterMount: true)
    }

    private func assertSuspendedHeroResumes(addSecondItemAfterMount: Bool) async throws {
        let model = StageDwellModel()
        model.hasSecondItem = !addSecondItemAfterMount
        let host = UIHostingController(rootView: StageDwellFixture(model: model))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        if addSecondItemAfterMount {
            try await Task.sleep(for: .milliseconds(100))
            model.hasSecondItem = true
        }
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertEqual(model.itemID, "first")
        model.suspended = false
        let deadline = ContinuousClock.now + .seconds(3)
        while model.itemID != "second", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(model.itemID, "second")
    }

    func testScrollPositionRetainsRequestedMotionAcrossAttachmentAndRemount() {
        let navigation = TopNavigationScroll()
        let motion = HeroShowcaseScrollMotion()
        let position = FocusHeroNativeScrollPosition.PositionView()
        position.navigation = navigation
        position.bindShowcaseMotion(motion)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        let rows = UIScrollView(frame: window.bounds)
        root.view.addSubview(rows)
        defer {
            position.stop()
            motion.stopAnimations()
            window.isHidden = true
            window.rootViewController = nil
        }
        motion.move(expanded: false, distance: 320, animated: false, reduceMotion: false)
        XCTAssertEqual(navigation.offset, 0)
        rows.addSubview(position)
        XCTAssertEqual(navigation.offset, 320)
        XCTAssertFalse(rows.isScrollEnabled)
        position.removeFromSuperview()
        XCTAssertTrue(rows.isScrollEnabled)
        XCTAssertFalse(navigation.scrollToTop())
        motion.move(expanded: true, distance: 320, animated: false, reduceMotion: false)
        rows.addSubview(position)
        XCTAssertEqual(navigation.offset, 0)
        motion.move(expanded: false, distance: 320, animated: false, reduceMotion: false)
        XCTAssertEqual(navigation.offset, 320)
        position.stop()
        XCTAssertFalse(navigation.scrollToTop())
        XCTAssertTrue(rows.isScrollEnabled)
    }

    func testProductionNestedHostsPreserveNavigationAndArtworkOwnership() async throws {
        let navigation = TopNavigationScroll()
        let artwork = HeroArtworkDisplayState()
        let ambient = AmbientBackdropModel()
        var environments: [String: EnvironmentValues] = [:]
        let rows = [FocusHeroRow(id: "first", itemIDs: [], leadItem: nil)]
        let host = UIHostingController(rootView: FocusHeroHomeView(
            rows: rows, settings: .default, spoilerSettings: .default,
            navigationStyle: .tabBar, isFrontmost: true,
            featuredHero: { suspended in
                AnyView(
                    Button("Featured") {}
                        .background(StageEnvironmentReader { environments["foreground"] = $0 })
                        .modifier(HeroShowcaseForeground(surface: .featured))
                        .heroArtworkSource(id: "featured", isActive: !suspended)
                )
            }
        ) { _, _ in
            Button("First row") {}
                .frame(width: 400, height: 300)
                .background(StageEnvironmentReader { environments["row"] = $0 })
        }
        .environment(\.plozzTopNavigationScroll, navigation)
        .environment(\.heroArtworkDisplayState, artwork)
        .environment(\.ambientBackdropModel, ambient))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        func findStage(_ controller: UIViewController) -> HeroShowcaseStage.Controller? {
            if let stage = controller as? HeroShowcaseStage.Controller { return stage }
            return controller.children.lazy.compactMap(findStage).first
        }
        let stage = try XCTUnwrap(findStage(host))
        defer { stage.stopAnimations() }
        for key in ["foreground", "row"] {
            let environment = try XCTUnwrap(environments[key], key)
            XCTAssertTrue(environment.heroShowcaseMotion === stage.state.motion, key)
            XCTAssertTrue(environment.plozzTopNavigationScroll === navigation, key)
            XCTAssertTrue(environment.heroArtworkDisplayState === artwork, key)
            XCTAssertTrue(environment.ambientBackdropModel === ambient, key)
        }
        XCTAssertEqual(
            environments["foreground"]?.heroArtworkDisplayReporter?.identity.state,
            ObjectIdentifier(artwork)
        )
        stage.present(expanded: false, focus: false)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertGreaterThan(stage.state.motion.distance, 0)
        XCTAssertEqual(navigation.offset, stage.state.motion.distance, accuracy: 1)
        XCTAssertTrue(navigation.scrollToTop())
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(stage.state.isExpanded)
        XCTAssertEqual(navigation.offset, 0, accuracy: 1)
    }

    func testNativeSidebarCountsTheHeroWithoutMovingTheFirstRow() async throws {
        for usesNativeSidebar in [false, true] {
            let state = HeroShowcaseState()
            state.motion.move(expanded: true, distance: 320.5, animated: false, reduceMotion: false)
            let model = FocusHeroModel()
            let rows = [FocusHeroRow(id: "first", itemIDs: [], leadItem: nil)]
            let marker = UIView()
            let host = UIHostingController(rootView: HeroShowcaseNativeRows(
                state: state, usesNativeSidebar: usesNativeSidebar
            ) { inset in
                AnyView(FocusHeroScrollingRows(
                    rows: rows, model: model,
                    rowContent: { _, _ in
                        StageLayoutMarker(view: marker, onMount: {})
                            .frame(width: 400, height: 320)
                    },
                    topInset: inset
                ))
            })
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true; window.rootViewController = nil }
            func findScroller(_ view: UIView) -> UIScrollView? {
                if let scroller = view as? UIScrollView { return scroller }
                return view.subviews.lazy.compactMap(findScroller).first
            }
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            let scroller = try XCTUnwrap(findScroller(host.view))
            let initialY = marker.convert(marker.bounds, to: window).midY
            for expanded in [false, true, false, true] {
                state.setExpanded(expanded)
                try await Task.sleep(for: .milliseconds(150))
                host.view.layoutIfNeeded()
                XCTAssertEqual(scroller.contentOffset.y, usesNativeSidebar && !expanded ? 320.5 : 0, accuracy: 0.5)
                XCTAssertEqual(marker.convert(marker.bounds, to: window).midY, initialY, accuracy: 0.5)
            }
        }
    }

    func testTopNavigationSharesNativeStageAnimationsWithoutFrameUpdates() throws {
        let navigation = TopNavigationScroll()
        let motion = HeroShowcaseScrollMotion()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        let rows = UIScrollView(frame: window.bounds)
        rows.contentSize = CGSize(width: 1920, height: 3000)
        root.view.addSubview(rows)
        let bar = UIView(frame: CGRect(x: 0, y: 40, width: 700, height: 68))
        root.view.addSubview(bar)
        navigation.bindMotionView(bar, maximumOffset: 124)
        let position = FocusHeroNativeScrollPosition.PositionView(frame: window.bounds)
        position.navigation = navigation
        rows.addSubview(position)
        motion.bind(rows, to: .rows)
        position.bindShowcaseMotion(motion)
        motion.move(expanded: true, distance: 320.5, animated: false, reduceMotion: false)
        defer {
            position.stop()
            motion.stopAnimations()
            navigation.unbindMotionView(bar)
            window.isHidden = true
            window.rootViewController = nil
        }
        CATransaction.begin()
        defer { CATransaction.commit() }
        for expanded in [false, true, false] {
            motion.move(expanded: expanded, distance: 320.5, animated: true, reduceMotion: false)
            let key = try XCTUnwrap(rows.layer.animationKeys()?.last)
            let animation = try XCTUnwrap(bar.layer.animation(forKey: key) as? CABasicAnimation)
            XCTAssertEqual(animation.fromValue as? CGFloat, expanded ? -124 : 124)
            XCTAssertEqual(animation.toValue as? CGFloat, 0)
            XCTAssertEqual(animation.beginTime, 0)
            XCTAssertEqual(animation.duration, HeroShowcaseScrollMotion.duration)
            try assertRowSpring(animation)
            XCTAssertTrue(animation.isAdditive)
            XCTAssertEqual(bar.transform.ty, expanded ? 0 : -124)
            XCTAssertEqual(navigation.stageTransition?.progress, expanded ? 0 : 1)
            XCTAssertEqual(bar.layer.animationKeys()?.count, rows.layer.animationKeys()?.count)
        }
        motion.move(expanded: true, distance: 320.5, animated: true, reduceMotion: true)
        XCTAssertNil(bar.layer.animationKeys())
        XCTAssertEqual(bar.transform.ty, 0)
        position.stop()
        motion.move(expanded: false, distance: 320.5, animated: true, reduceMotion: false)
        XCTAssertNil(bar.layer.animationKeys())
        XCTAssertEqual(bar.transform.ty, 0)
    }

    func testTopNavigationSeparatesStageProgressFromItsFocusAndResetOffset() {
        let navigation = TopNavigationScroll()
        let source = UUID()
        navigation.register(source: source, offset: 0) {}
        for offset: CGFloat in [0, 320.5] {
            for progress: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
                navigation.update(offset: offset, source: source, stageTransition: .init(offset: offset, progress: progress))
                XCTAssertEqual(navigation.offset, offset)
                XCTAssertEqual(navigation.visibleOffset(maximum: 124), progress * 124)
            }
        }
        navigation.update(offset: 500, source: source, stageTransition: .init(offset: 320.5, progress: 1))
        XCTAssertEqual(navigation.visibleOffset(maximum: 124), 124)
        XCTAssertTrue(navigation.scrollToTop())
        XCTAssertEqual(navigation.visibleOffset(maximum: 124), 0)
        XCTAssertNil(navigation.stageTransition)
        let replacement = UUID()
        navigation.register(source: replacement, offset: 40) {}
        navigation.update(offset: 320.5, source: source, stageTransition: .init(offset: 320.5, progress: 1))
        navigation.unregister(source: source)
        XCTAssertNil(navigation.stageTransition)
        XCTAssertEqual(navigation.visibleOffset(maximum: 124), 40)
        navigation.unregister(source: replacement)
        XCTAssertEqual(navigation.visibleOffset(maximum: 124), 0)
    }

    func testTopNavigationClearsNativeAnimationsWhenItsSourceOrSurfaceLeaves() {
        let navigation = TopNavigationScroll()
        let source = UUID()
        let replacement = UUID()
        let bar = UIView()
        navigation.bindMotionView(bar, maximumOffset: 124)
        navigation.register(source: source, offset: 320) {}
        navigation.animateStage(
            from: -1, spring: HeroShowcaseScrollMotion.spring,
            key: "first", source: source
        )
        XCTAssertNotNil(bar.layer.animation(forKey: "first"))
        navigation.register(source: replacement, offset: 40) {}
        XCTAssertNil(bar.layer.animationKeys())
        XCTAssertEqual(bar.transform.ty, -40)
        navigation.animateStage(
            from: -1, spring: HeroShowcaseScrollMotion.spring,
            key: "stale", source: source
        )
        XCTAssertNil(bar.layer.animationKeys())
        navigation.animateStage(
            from: -1, spring: HeroShowcaseScrollMotion.spring,
            key: "replacement", source: replacement
        )
        navigation.unbindMotionView(bar)
        XCTAssertNil(bar.layer.animationKeys())
        let newBar = UIView()
        navigation.bindMotionView(newBar, maximumOffset: 124)
        XCTAssertEqual(newBar.transform.ty, -40)
        XCTAssertNil(newBar.layer.animationKeys())
        navigation.unregister(source: replacement)
        XCTAssertEqual(newBar.transform.ty, 0)
        navigation.unbindMotionView(newBar)
    }

    func testStageNavigationBindingHandlesReducedMotionAndDeparture() {
        let navigation = TopNavigationScroll()
        let motion = HeroShowcaseScrollMotion()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        let scroll = UIScrollView(frame: window.bounds)
        scroll.contentSize = CGSize(width: 1920, height: 3000)
        root.view.addSubview(scroll)
        let position = FocusHeroNativeScrollPosition.PositionView(frame: window.bounds)
        position.navigation = navigation
        scroll.addSubview(position)
        position.bindShowcaseMotion(motion)
        defer { position.stop(); motion.stopAnimations(); window.isHidden = true; window.rootViewController = nil }
        for expanded in [false, true, false] {
            motion.move(expanded: expanded, distance: 320.5, animated: true, reduceMotion: true)
            XCTAssertEqual(navigation.offset, expanded ? 0 : 320.5)
            XCTAssertEqual(navigation.visibleOffset(maximum: 124), expanded ? 0 : 124)
            XCTAssertEqual(scroll.contentOffset.y, 0)
        }
        position.onReturnToTop = {
            motion.move(expanded: true, distance: 320.5, animated: true, reduceMotion: false)
        }
        XCTAssertTrue(navigation.scrollToTop())
        XCTAssertEqual(navigation.visibleOffset(maximum: 124), 0)
        XCTAssertNil(navigation.stageTransition)
        position.stop()
        motion.move(expanded: false, distance: 400, animated: true, reduceMotion: false)
        XCTAssertEqual(navigation.offset, 0)
        XCTAssertNil(navigation.stageTransition)
    }

    func testTopNavigationIncludesTheFeaturedStageWithoutMovingRowContent() {
        for rowOffset: CGFloat in [0, 180] {
            let navigation = TopNavigationScroll()
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
            let root = UIViewController()
            window.rootViewController = root
            window.isHidden = false
            let scroll = UIScrollView(frame: window.bounds)
            scroll.contentSize = CGSize(width: 1920, height: 3000)
            root.view.addSubview(scroll)
            let position = FocusHeroNativeScrollPosition.PositionView(frame: window.bounds)
            position.navigation = navigation
            var returns = 0
            position.onReturnToTop = {
                returns += 1
                position.updateNavigationOffset(0)
            }
            scroll.addSubview(position)
            defer {
                position.onReturnToTop = nil
                position.stop()
                window.isHidden = true
                window.rootViewController = nil
            }
            position.move(to: rowOffset, rowID: "row")
            XCTAssertEqual(navigation.offset, rowOffset)
            position.updateNavigationOffset(320)
            XCTAssertEqual(navigation.offset, rowOffset + 320)
            XCTAssertEqual(scroll.contentOffset.y, rowOffset)
            XCTAssertTrue(navigation.scrollToTop())
            XCTAssertEqual(returns, 1)
            XCTAssertEqual(navigation.offset, 0)
            XCTAssertEqual(scroll.contentOffset.y, 0)
            XCTAssertFalse(navigation.scrollToTop())
            position.updateNavigationOffset(320)
            position.removeFromSuperview()
            XCTAssertEqual(navigation.offset, 0, "A departing page must not hide another destination's navigation.")
        }
    }

    func testPendingBoundaryHandoffCannotReleaseDirectionalFocusToNavigation() {
        for expanded in [false, true] {
            let stage = HeroShowcaseStage.Controller(
                state: HeroShowcaseState(), hero: AnyView(Color.clear),
                showcase: AnyView(Color.clear), rows: AnyView(Color.clear)
            )
            stage.loadViewIfNeeded()
            stage.present(expanded: expanded, focus: false)
            defer { stage.stopAnimations() }
            let source = StageVirtualFocusItem(parent: expanded ? stage.hero.view : stage.rows.view)
            let navigation = StageVirtualFocusItem(parent: UIView())
            let heading: UIFocusHeading = expanded ? .down : .up
            XCTAssertFalse(stage.allowsFocusUpdate(from: source, to: navigation, heading: heading))
            XCTAssertFalse(
                stage.allowsFocusUpdate(from: source, to: navigation, heading: heading),
                "A second focus proposal before the deferred handoff must not escape to navigation."
            )
            XCTAssertTrue(stage.allowsFocusUpdate(
                from: source, to: navigation, heading: .left
            ), "Unrelated navigation must remain available.")
            XCTAssertTrue(stage.allowsFocusUpdate(
                from: source, to: source, heading: []
            ), "The explicit destination request must not be blocked.")
        }
    }

    func testBoundaryGatePreservesNavigationAndDeeperRowMovement() {
        let stage = HeroShowcaseStage.Controller(
            state: HeroShowcaseState(), hero: AnyView(Color.clear),
            showcase: AnyView(Color.clear), rows: AnyView(Color.clear)
        )
        stage.loadViewIfNeeded()
        defer { stage.stopAnimations() }
        let hero = StageVirtualFocusItem(parent: stage.hero.view)
        let row = StageVirtualFocusItem(parent: stage.rows.view)
        let navigation = StageVirtualFocusItem(parent: UIView())
        XCTAssertTrue(stage.allowsFocusUpdate(from: navigation, to: hero, heading: .down))
        XCTAssertTrue(stage.allowsFocusUpdate(from: hero, to: navigation, heading: .up))
        XCTAssertTrue(stage.allowsFocusUpdate(from: hero, to: hero, heading: .down))
        stage.canEnterRows = { false }
        XCTAssertTrue(stage.allowsFocusUpdate(from: hero, to: navigation, heading: .down))
        stage.present(expanded: false, focus: false)
        stage.canReturn = { false }
        XCTAssertTrue(stage.allowsFocusUpdate(from: row, to: row, heading: .up))
        XCTAssertTrue(stage.allowsFocusUpdate(from: row, to: navigation, heading: .left))
    }

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
                try assertRowSpring(animation)
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
                try assertRowSpring(animation)
                for oldKey in oldKeys { XCTAssertNotNil(view.layer.animation(forKey: oldKey)) }
            }
            oldKeys.append(key)
        }
        motion.stopAnimations()
        for view in [featured, backdrop, showcase, showcaseBackdrop, rows] { XCTAssertNil(view.layer.animationKeys()) }
    }

    private func assertRowSpring(_ animation: CAAnimation, file: StaticString = #filePath, line: UInt = #line) throws {
        let spring = try XCTUnwrap(animation as? CASpringAnimation, file: file, line: line)
        XCTAssertEqual(spring.mass, FocusHeroLayout.rowSpring.mass, file: file, line: line)
        XCTAssertEqual(spring.stiffness, FocusHeroLayout.rowSpring.stiffness, file: file, line: line)
        XCTAssertEqual(spring.damping, FocusHeroLayout.rowSpring.damping, file: file, line: line)
        XCTAssertEqual(spring.duration, FocusHeroLayout.rowSpring.settlingDuration, file: file, line: line)
        XCTAssertNil(spring.timingFunction, file: file, line: line)
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

    func testReturnChevronCentersOnTheDisplayAndStaysHiddenAfterEnteringFromHero() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        let cue = HeroShowcaseReturnCue.CueView()
        root.view.addSubview(cue)
        defer { cue.update(rowID: nil, index: nil); window.isHidden = true; window.rootViewController = nil }
        cue.frame = CGRect(x: 80, y: 0, width: 1840, height: 1080)
        cue.layoutIfNeeded()
        let frame = cue.arrow.convert(cue.arrow.bounds, to: window)
        XCTAssertEqual(frame.midX, window.bounds.midX, accuracy: 0.5)
        XCTAssertEqual(frame.midY, 48, accuracy: 0.5)
        XCTAssertFalse(cue.isUserInteractionEnabled)
        XCTAssertTrue(cue.accessibilityElementsHidden)
        XCTAssertEqual(cue.arrow.alpha, 0)
        cue.update(rowID: "first", index: 0)
        XCTAssertFalse(cue.isEligible)
        try await Task.sleep(for: .milliseconds(2200))
        XCTAssertEqual(cue.arrow.alpha, 0)
        cue.top = 132
        cue.layoutIfNeeded()
        XCTAssertEqual(cue.arrow.convert(cue.arrow.bounds, to: window).midY, 132, accuracy: 0.5)
    }

    func testReturnChevronWaitsTwoSecondsAfterUpwardArrivalAndDoesNotRestartWithinRow() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        let cue = HeroShowcaseReturnCue.CueView()
        root.view.addSubview(cue)
        defer { cue.update(rowID: nil, index: nil); window.isHidden = true; window.rootViewController = nil }
        cue.update(rowID: "lower", index: 2)
        cue.update(rowID: "first", index: 0)
        XCTAssertTrue(cue.isEligible)
        XCTAssertEqual(cue.arrow.alpha, 0)
        try await Task.sleep(for: .milliseconds(1700))
        XCTAssertEqual(cue.arrow.alpha, 0, "The hint must not appear during quick upward navigation")
        cue.update(rowID: "first", index: 0)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(cue.arrow.alpha, 1, "Same-row updates must not reset the two-second delay")
        try await Task.sleep(for: .milliseconds(3200))
        XCTAssertEqual(cue.arrow.alpha, 0)
        cue.update(rowID: "first", index: 0)
        XCTAssertEqual(cue.arrow.alpha, 0, "An expired hint stays hidden until a new upward arrival")
    }

    func testReturnChevronCancelsFastUpwardPassAndNeverReplaysOnDownwardReturn() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        let cue = HeroShowcaseReturnCue.CueView()
        root.view.addSubview(cue)
        defer { cue.update(rowID: nil, index: nil); window.isHidden = true; window.rootViewController = nil }
        cue.update(rowID: "lower", index: 1)
        cue.update(rowID: "first", index: 0)
        try await Task.sleep(for: .milliseconds(200))
        cue.update(rowID: nil, index: nil)
        cue.update(rowID: "first", index: 0)
        XCTAssertFalse(cue.isEligible)
        try await Task.sleep(for: .milliseconds(2200))
        XCTAssertEqual(cue.arrow.alpha, 0, "Returning down from the hero must not revive the cancelled hint")
        cue.update(rowID: "lower", index: 1)
        cue.update(rowID: "first", index: 0)
        cue.update(rowID: "lower", index: 1)
        XCTAssertFalse(cue.isEligible)
        try await Task.sleep(for: .milliseconds(2200))
        XCTAssertEqual(cue.arrow.alpha, 0, "Leaving the first row downward also cancels the hint")
    }

    func testReturnChevronClearsArrivalOnDetachAndIgnoresRowReordering() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        let cue = HeroShowcaseReturnCue.CueView()
        root.view.addSubview(cue)
        defer { cue.update(rowID: nil, index: nil); window.isHidden = true; window.rootViewController = nil }
        cue.update(rowID: "same", index: 1)
        cue.update(rowID: "same", index: 0)
        XCTAssertFalse(cue.isEligible, "A row moving in the list is not upward navigation")
        cue.update(rowID: "lower", index: 1)
        cue.update(rowID: "missing", index: nil)
        cue.update(rowID: "first", index: 0)
        XCTAssertFalse(cue.isEligible, "Removing the active row cannot count as returning upward")
        cue.update(rowID: "lower", index: 1)
        cue.update(rowID: "first", index: 0)
        XCTAssertTrue(cue.isEligible)
        cue.removeFromSuperview()
        XCTAssertFalse(cue.isEligible)
        root.view.addSubview(cue)
        cue.update(rowID: "first", index: 0)
        try await Task.sleep(for: .milliseconds(2200))
        XCTAssertEqual(cue.arrow.alpha, 0)
    }

    func testReturnChevronObservesHostedRowArrivalAndResetsWhenHeroReturns() async throws {
        let model = FocusHeroModel()
        let state = HeroShowcaseState()
        let rows = [
            FocusHeroRow(id: "first", itemIDs: [], leadItem: nil),
            FocusHeroRow(id: "lower", itemIDs: [], leadItem: nil)
        ]
        let host = UIHostingController(rootView: HeroShowcaseFeaturedContent(state: state) { active in
            AnyView(HeroShowcaseReturnCue(model: model, rows: rows, isActive: active))
        })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        func findCue(in view: UIView) -> HeroShowcaseReturnCue.CueView? {
            if let cue = view as? HeroShowcaseReturnCue.CueView { return cue }
            return view.subviews.lazy.compactMap { findCue(in: $0) }.first
        }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let cue = try XCTUnwrap(findCue(in: host.view))
        model.activate(rows[0], in: rows)
        state.setExpanded(false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(cue.isEligible)
        model.activate(rows[1], in: rows)
        try await Task.sleep(for: .milliseconds(100))
        model.activate(rows[0], in: rows)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(cue.isEligible)
        XCTAssertEqual(cue.arrow.alpha, 0)
        try await Task.sleep(for: .milliseconds(2100))
        XCTAssertEqual(cue.arrow.alpha, 1)
        state.setExpanded(true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(cue.isEligible)
        XCTAssertEqual(cue.arrow.alpha, 0)
        state.setExpanded(false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(cue.isEligible, "Down from the hero cannot reuse an earlier upward arrival")
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

private struct StageEnvironmentReader: UIViewRepresentable {
    let read: (EnvironmentValues) -> Void

    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ uiView: UIView, context: Context) { read(context.environment) }
}

@MainActor
@Observable
private final class StageDwellModel {
    var suspended = true
    var hasSecondItem = true
    var itemID: String?
}

private struct StageDwellFixture: View {
    let model: StageDwellModel
    @Namespace private var focus
    @State private var trailer = HeroTrailerController()
    @State private var recede = HomeHeroRecedeModel()

    var body: some View {
        var settings = HeroSettings.default
        settings.autoAdvance = true
        settings.autoAdvanceSeconds = 1
        var background = HeroBackgroundSettings.default
        background.homeTrailerEnabled = false
        let items = [MediaItem(id: "first", title: "First", kind: .movie)]
            + (model.hasSecondItem ? [MediaItem(id: "second", title: "Second", kind: .movie)] : [])
        return HomeHeroView(
            items: items,
            settings: settings, backgroundSettings: background,
            trailerController: trailer, trailerResolver: { _ in nil },
            isFrontmost: true, spoilerSettings: .default, navigationStyle: .rail,
            focusScope: focus, onSelect: { _ in }, onPlay: { _ in },
            onPinnedItemsChanged: { model.itemID = $0.first },
            recedeModel: recede, showcaseSuspended: model.suspended
        )
    }
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
