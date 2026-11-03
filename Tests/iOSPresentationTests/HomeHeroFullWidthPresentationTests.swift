#if os(iOS)
import CoreModels
import CoreUI
import FeatureAuth
import FeatureHomeCore
import SwiftUI
import UIKit
import XCTest
@testable import AppShelliOS

@MainActor
final class HomeHeroFullWidthPresentationTests: XCTestCase {
    func testPendingParentShowPaintsArtworkAndTitleInsteadOfABlackSpinner() async throws {
        var item = try await artworkItem()
        item.kind = .episode
        item.title = "EPISODE"
        item.parentTitle = "SHOW"
        item.seriesID = "show"
        item.overview = "EPISODE SPOILERS"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SeriesPreview-\(UUID().uuidString)"))
        let app = PlozziOSAppModel(
            accountStore: AccountStore(secureStore: InMemorySecureStore()),
            profileStore: ProfileStore(defaults: defaults)
        )
        let trailer = HeroTrailerController()
        for (size, sizeClass) in [
            (CGSize(width: 390, height: 844), UserInterfaceSizeClass.compact),
            (CGSize(width: 1024, height: 768), .regular)
        ] {
            try await withWindow(
                item: item, size: size, sizeClass: sizeClass, insets: .zero,
                pull: PlozziOSHomeHeroPullModel()
            ) { window, host in
                host.rootView = AnyView(
                    PlozziOSSeriesLoadingHero(item: item, appModel: app)
                        .environment(trailer)
                        .environment(PlozziOSSidebarGeometryModel())
                        .environment(\.horizontalSizeClass, sizeClass)
                        .environment(\.themePalette, .dark)
                        .environment(\.colorScheme, .dark)
                )
                try await waitForHostedLayout(window)
                let image = snapshot(window, name: "pending-series-\(Int(size.width))")
                let color = try pixel(image, at: CGPoint(x: size.width / 2, y: 120))
                XCTAssertGreaterThan(color[2], 120, "The incoming page must already contain the known artwork.")
                let text = try HeroTextInk.frames(in: image, terms: ["SHOW", "SPOILERS", "Loading"])
                XCTAssertNotNil(text["SHOW"])
                XCTAssertNil(text["SPOILERS"], "A parent-show preview must not reveal the child's synopsis.")
                XCTAssertNil(text["Loading"], "Loading status is accessible, not a visible replacement page.")
                XCTAssertFalse(trailer.isPlaying)
                XCTAssertFalse(descendants(window).contains { $0 is UIActivityIndicatorView })
            }
        }
    }

    func testNativePushKeepsHomeSnapshotOutsideTheMovingPagesAndRemovesIt() async throws {
        let item = try await artworkItem()
        for size in [CGSize(width: 390, height: 844), CGSize(width: 1024, height: 768)] {
            try await withWindow(
                item: item, size: size, sizeClass: size.width < 600 ? .compact : .regular,
                insets: .zero, pull: PlozziOSHomeHeroPullModel()
            ) { window, host in
                let navigation = try XCTUnwrap(findController(UINavigationController.self, in: host))
                let originalDelegate = navigation.delegate
                let originalGestureDelegate = navigation.interactivePopGestureRecognizer?.delegate
                let source = try XCTUnwrap(navigation.topViewController)
                let sourceFrame = source.view.convert(source.view.bounds, to: window)
                let destination = UIViewController()
                destination.view.backgroundColor = .systemGreen
                navigation.pushViewController(destination, animated: true)
                let coordinator = try XCTUnwrap(navigation.transitionCoordinator)
                let finished = expectation(description: "Native detail push finishes")
                var heldSnapshot: UIView?
                coordinator.animate { context in
                    let snapshots = self.descendants(context.containerView).filter {
                        $0.accessibilityIdentifier == "home-navigation-source-snapshot"
                    }
                    XCTAssertEqual(snapshots.count, 1)
                    guard let snapshot = snapshots.first else { return }
                    heldSnapshot = snapshot
                    XCTAssertTrue(snapshot.superview === context.containerView)
                    XCTAssertEqual(snapshot.convert(snapshot.bounds, to: window), sourceFrame)
                    XCTAssertFalse(snapshot.isUserInteractionEnabled)
                    XCTAssertTrue(snapshot.accessibilityElementsHidden)
                    XCTAssertFalse(snapshot.isDescendant(of: source.view))
                    XCTAssertFalse(snapshot.isDescendant(of: destination.view))
                } completion: { _ in
                    finished.fulfill()
                }
                await fulfillment(of: [finished], timeout: 5)
                XCTAssertNotNil(heldSnapshot)
                XCTAssertNil(heldSnapshot?.superview)
                XCTAssertTrue(navigation.delegate === originalDelegate)
                XCTAssertTrue(navigation.interactivePopGestureRecognizer?.delegate === originalGestureDelegate)
                XCTAssertTrue(navigation.topViewController === destination)
                navigation.popViewController(animated: false)
                try await waitForHostedLayout(window)
                XCTAssertTrue(navigation.topViewController === source)
                XCTAssertFalse(descendants(window).contains {
                    $0.accessibilityIdentifier == "home-navigation-source-snapshot"
                })
            }
        }
    }

    func testUnanimatedNavigationDoesNotCaptureHome() async throws {
        let item = try await artworkItem()
        try await withWindow(
            item: item, size: CGSize(width: 390, height: 844), sizeClass: .compact,
            insets: .zero, pull: PlozziOSHomeHeroPullModel()
        ) { window, host in
            let navigation = try XCTUnwrap(findController(UINavigationController.self, in: host))
            navigation.pushViewController(UIViewController(), animated: false)
            try await waitForHostedLayout(window)
            XCTAssertFalse(descendants(window).contains {
                $0.accessibilityIdentifier == "home-navigation-source-snapshot"
            })
        }
    }

    func testMacHeroKeyboardPagesBothWaysAndReleasesKeysWhenScrolledAway() async throws {
        let item = try await artworkItem()
        let second = MediaItem(
            id: "keyboard-next", title: "NEXT HERO", kind: .movie,
            backdropURL: item.backdropURL, allowsTitleBasedMetadataMatching: false
        )
        let pull = PlozziOSHomeHeroPullModel()
        var pinned: Set<String> = []
        var expectedID: String?
        var selection: XCTestExpectation?
        try await withWindow(
            item: item, size: CGSize(width: 1280, height: 720), sizeClass: .regular,
            insets: .zero, pull: pull, isRunningOnMac: true, heroItems: [item, second],
            onHeroPinnedItemsChanged: { ids in
                pinned = ids
                if let expectedID, ids == [expectedID] { selection?.fulfill() }
            }
        ) { window, host in
            let controller = try XCTUnwrap(findController(
                PlozziOSHeroKeyboardControls.KeyboardViewController.self, in: host
            ))
            let left = try XCTUnwrap(controller.keyCommands?.first { $0.input == UIKeyCommand.inputLeftArrow })
            let right = try XCTUnwrap(controller.keyCommands?.first { $0.input == UIKeyCommand.inputRightArrow })
            let rightAction = try XCTUnwrap(right.action)
            XCTAssertTrue(controller.isFirstResponder)
            XCTAssertEqual(pinned, [item.id])
            for (command, target) in [(right, second.id), (left, item.id), (left, second.id)] {
                expectedID = target
                let changed = expectation(description: "Hero selected \(target)")
                selection = changed
                let action = try XCTUnwrap(command.action)
                XCTAssertTrue(UIApplication.shared.sendAction(action, to: nil, from: command, for: nil))
                await fulfillment(of: [changed], timeout: 3)
                expectedID = nil
                selection = nil
                XCTAssertEqual(pinned, [target])
            }
            pull.isVisible = false
            try await waitForHostedLayout(window)
            XCTAssertFalse(controller.isFirstResponder)
            XCTAssertFalse(controller.canPerformAction(rightAction, withSender: right))
            XCTAssertEqual(pinned, [second.id])
            pull.isVisible = true
            try await waitForHostedLayout(window)
            XCTAssertTrue(controller.isFirstResponder)
            XCTAssertTrue(controller.canPerformAction(rightAction, withSender: right))
        }
    }

    func testMacHeroKeyboardDoesNotStealTextEditingOrHandleKeysBehindDialogs() async throws {
        let item = try await artworkItem()
        try await withWindow(
            item: item, size: CGSize(width: 1280, height: 720), sizeClass: .regular,
            insets: .zero, pull: PlozziOSHomeHeroPullModel()
        ) { window, host in
            var pages: [Bool] = []
            XCTAssertNil(findController(PlozziOSHeroKeyboardControls.KeyboardViewController.self, in: host))
            host.rootView = AnyView(PlozziOSHeroKeyboardControls(isEnabled: true, onPage: { pages.append($0) }))
            try await waitForHostedLayout(window)
            let controller = try XCTUnwrap(findController(
                PlozziOSHeroKeyboardControls.KeyboardViewController.self, in: host
            ))
            let right = try XCTUnwrap(controller.keyCommands?.first { $0.input == UIKeyCommand.inputRightArrow })
            let action = try XCTUnwrap(right.action)
            let modified = UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: .command, action: action)
            XCTAssertFalse(controller.canPerformAction(action, withSender: modified))
            let field = UITextField(frame: CGRect(x: 80, y: 80, width: 200, height: 44))
            field.inputView = UIView()
            window.addSubview(field)
            defer { field.removeFromSuperview() }
            XCTContext.runActivity(named: "Text field takes keyboard ownership") { _ in
                XCTAssertTrue(field.becomeFirstResponder())
            }
            controller.updateResponder()
            XCTAssertTrue(field.isFirstResponder)
            XCTAssertFalse(controller.canPerformAction(action, withSender: right))
            XCTAssertTrue(pages.isEmpty)
            XCTAssertTrue(field.resignFirstResponder())
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            XCTAssertTrue(controller.isFirstResponder)
            field.removeFromSuperview()

            await withCheckedContinuation { continuation in
                host.present(UIViewController(), animated: false) { continuation.resume() }
            }
            controller.updateResponder()
            XCTAssertFalse(controller.canPerformAction(action, withSender: right))
            XCTAssertFalse(controller.isFirstResponder)
            await withCheckedContinuation { continuation in
                host.dismiss(animated: false) { continuation.resume() }
            }
            controller.updateResponder()
            XCTAssertTrue(controller.canPerformAction(action, withSender: right))
            XCTAssertTrue(UIApplication.shared.sendAction(action, to: nil, from: right, for: nil))
            XCTAssertEqual(pages, [true])
            PlozziOSHeroKeyboardControls.dismantleUIViewController(controller, coordinator: ())
            XCTAssertFalse(controller.isFirstResponder)
            XCTAssertFalse(controller.canPerformAction(action, withSender: right))
            XCTAssertNil(controller.onPage)
        }
    }

    func testPointerActivityFreezesProgressAndResumesOnlyAfterTheLastMovement() throws {
        let activity = HeroPointerActivity()
        var dwellStart = Date(timeIntervalSinceReferenceDate: 100)
        let firstMovement = dwellStart.addingTimeInterval(4)
        let nextMovement = firstMovement.addingTimeInterval(1)
        var gaugeReads = 0
        func gauge() -> HeroGaugeState {
            gaugeReads += 1
            return HeroGaugeState(fraction: 0.4, remaining: 6)
        }

        activity.recordMovement(at: firstMovement, gauge: gauge())
        let pauseID = activity.pauseID
        activity.recordMovement(at: nextMovement, gauge: gauge())
        XCTAssertEqual(gaugeReads, 1, "Mouse movement must not resample or redraw the gauge every pixel.")
        XCTAssertEqual(activity.pauseID, pauseID)
        XCTAssertEqual(activity.frozenGauge, HeroGaugeState(fraction: 0.4, remaining: nil))
        let deadline = try XCTUnwrap(activity.resumeDeadline)
        XCTAssertEqual(deadline, nextMovement.addingTimeInterval(HeroPointerActivity.idleDelay))
        XCTAssertNil(activity.resumeIfIdle(at: deadline.addingTimeInterval(-0.001)))
        let resumption = try XCTUnwrap(activity.resumeIfIdle(at: deadline))
        XCTAssertFalse(resumption.advanceAfterTrailer)
        dwellStart += resumption.pausedDuration
        let resumed = HeroGaugeState.resolve(
            autoAdvance: true, dwellStart: dwellStart, dwellDuration: 10, now: deadline
        )
        XCTAssertEqual(resumed.fraction, 0.4, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(resumed.remaining), 6, accuracy: 0.001)
        XCTAssertFalse(activity.isPaused)
        XCTAssertNil(activity.resumeIfIdle(at: deadline))
    }

    func testPointerPauseHoldsTrailerProgressAndDefersItsEndOnlyOnce() throws {
        let activity = HeroPointerActivity()
        let start = Date(timeIntervalSinceReferenceDate: 100)
        func trailerGauge(elapsed: Double) -> HeroGaugeState {
            HeroGaugeState.resolve(
                autoAdvance: true, dwellStart: start, dwellDuration: 10, now: start,
                trailerElapsed: elapsed, trailerDuration: 120
            )
        }
        activity.recordMovement(at: start, gauge: trailerGauge(elapsed: 30))
        activity.recordMovement(at: start.addingTimeInterval(1), gauge: trailerGauge(elapsed: 60))
        XCTAssertEqual(activity.frozenGauge, HeroGaugeState(fraction: 0.25, remaining: nil))
        XCTAssertTrue(activity.deferAdvanceIfPaused())
        XCTAssertTrue(activity.deferAdvanceIfPaused())
        let deadline = try XCTUnwrap(activity.resumeDeadline)
        let resumption = try XCTUnwrap(activity.resumeIfIdle(at: deadline))
        XCTAssertTrue(resumption.advanceAfterTrailer)
        XCTAssertNil(activity.resumeIfIdle(at: deadline))
        XCTAssertFalse(activity.deferAdvanceIfPaused())
    }

    func testManualPagingDiscardsDeferredTrailerAndStartsANewPausedDwell() throws {
        let activity = HeroPointerActivity()
        let start = Date(timeIntervalSinceReferenceDate: 100)
        activity.recordMovement(at: start, gauge: HeroGaugeState(fraction: 0.8, remaining: 2))
        XCTAssertTrue(activity.deferAdvanceIfPaused())
        activity.resetSlide(at: start.addingTimeInterval(1))
        XCTAssertEqual(activity.frozenGauge, HeroGaugeState(fraction: 0, remaining: nil))
        let resumption = try XCTUnwrap(activity.resumeIfIdle(at: start.addingTimeInterval(1.5)))
        XCTAssertEqual(resumption.pausedDuration, 0.5)
        XCTAssertFalse(resumption.advanceAfterTrailer)
    }

    func testPointerExitAndLifecycleResetCannotLeaveAStalePause() throws {
        let activity = HeroPointerActivity()
        let start = Date(timeIntervalSinceReferenceDate: 100)
        activity.recordMovement(at: start, gauge: HeroGaugeState(fraction: 0.4, remaining: 6))
        let firstID = activity.pauseID
        let resumption = try XCTUnwrap(activity.resume(at: start.addingTimeInterval(0.25)))
        XCTAssertEqual(resumption.pausedDuration, 0.25)
        activity.recordMovement(at: start.addingTimeInterval(0.3), gauge: HeroGaugeState(fraction: 0.4, remaining: 6))
        XCTAssertNotEqual(activity.pauseID, firstID, "A new pause must rearm the idle task even within one render.")
        XCTAssertTrue(activity.deferAdvanceIfPaused())
        activity.reset()
        XCTAssertNil(activity.pauseID)
        XCTAssertNil(activity.resumeDeadline)
        XCTAssertNil(activity.frozenGauge)
        XCTAssertNil(activity.resumeIfIdle(at: start.addingTimeInterval(100)))
    }

    func testPagingIndicatorHoldsTheCapturedGaugeWithoutDisablingAutoAdvance() {
        let start = Date(timeIntervalSinceReferenceDate: 100)
        var indicator = PlozziOSHeroPagingIndicator(
            itemIDs: ["first", "second"], selectedItemID: "first", autoAdvance: true,
            autoAdvanceSeconds: 10, dwellStart: start,
            pausedGauge: HeroGaugeState(fraction: 0.4, remaining: nil),
            trailerController: HeroTrailerController()
        )
        for offset in [4.0, 8, 20] {
            XCTAssertEqual(
                indicator.gauge(at: start.addingTimeInterval(offset)),
                HeroGaugeState(fraction: 0.4, remaining: nil)
            )
        }
        indicator.isTransitioning = true
        XCTAssertEqual(indicator.gauge(at: start.addingTimeInterval(4)).fraction, 0)
    }

    func testMacHeroPagingControlsAppearAtBothEdgesOnlyForMultipleTitles() async throws {
        let item = try await artworkItem()
        try await withWindow(
            item: item, size: CGSize(width: 1280, height: 720), sizeClass: .regular,
            insets: .zero, pull: PlozziOSHomeHeroPullModel()
        ) { window, host in
            for width in [CGFloat(390), 1280, 1920] {
                window.frame = CGRect(x: 0, y: 0, width: width, height: 720)
                for isRunningOnMac in [false, true] {
                    for count in [0, 1, 3] {
                        host.rootView = AnyView(
                            ZStack {
                                Color.black
                                PlozziOSHeroPagingControls(
                                    itemCount: count, isEnabled: true, onPage: { _ in }
                                )
                            }
                            .ignoresSafeArea()
                            .environment(\.plozziOSIsRunningOnMac, isRunningOnMac)
                        )
                        try await waitForHostedLayout(window)
                        let image = snapshot(
                            window, name: "hero-arrows-\(Int(width))-mac-\(isRunningOnMac)-count-\(count)"
                        )
                        for centerX in [CGFloat(30), width - 30] {
                            let region = CGRect(x: centerX - 22, y: 328, width: 44, height: 64)
                            let ink = try pagingControlInk(in: image, region: region).bounds
                            if isRunningOnMac, count > 1 {
                                let bounds = try XCTUnwrap(ink)
                                XCTAssertEqual(bounds.midX, centerX, accuracy: 2)
                                XCTAssertEqual(bounds.midY, 360, accuracy: 2)
                                XCTAssertGreaterThan(bounds.height, 25)
                                XCTAssertLessThan(bounds.height, 28)
                                XCTAssertLessThan(bounds.width, bounds.height * 0.4)
                                // The native hover highlight must not leave a permanent pill.
                                XCTAssertEqual(try pixel(image, at: CGPoint(x: centerX, y: 335))[0], 0)
                            } else {
                                XCTAssertNil(ink, "Only a multi-title Mac hero should have paging arrows.")
                            }
                        }
                    }
                }
            }
        }
    }

    func testMacHeroChevronsRespectIncreasedContrastAndBoldText() async throws {
        let item = try await artworkItem()
        try await withWindow(
            item: item, size: CGSize(width: 1280, height: 720), sizeClass: .regular,
            insets: .zero, pull: PlozziOSHomeHeroPullModel()
        ) { window, host in
            var samples: [(pixels: Int, peak: UInt8)] = []
            for (contrast, weight) in [
                (ColorSchemeContrast.standard, LegibilityWeight.regular),
                (.increased, .regular),
                (.standard, .bold)
            ] {
                host.traitOverrides.accessibilityContrast = contrast == .increased ? .high : .normal
                host.rootView = AnyView(
                    ZStack {
                        Color.black
                        PlozziOSHeroPagingControls(itemCount: 3, isEnabled: true, onPage: { _ in })
                    }
                    .ignoresSafeArea()
                    .environment(\.plozziOSIsRunningOnMac, true)
                    .environment(\.legibilityWeight, weight)
                )
                try await waitForHostedLayout(window)
                let image = snapshot(window, name: "hero-chevron-\(contrast)-\(weight)")
                let ink = try pagingControlInk(
                    in: image, region: CGRect(x: 8, y: 328, width: 44, height: 64)
                )
                let bounds = try XCTUnwrap(ink.bounds)
                XCTAssertEqual(bounds.midX, 30, accuracy: 2)
                XCTAssertEqual(bounds.midY, 360, accuracy: 2)
                samples.append((ink.pixels, ink.peak))
            }
            XCTAssertGreaterThan(Int(samples[1].peak), Int(samples[0].peak) + 20)
            XCTAssertGreaterThan(samples[2].pixels, samples[0].pixels)
        }
    }

    func testMacHeroHoverPaintsAndClearsTheBackgroundWithoutShrinkingTheButton() async throws {
        let item = try await artworkItem()
        try await withWindow(
            item: item, size: CGSize(width: 1280, height: 720), sizeClass: .regular,
            insets: .zero, pull: PlozziOSHomeHeroPullModel()
        ) { window, host in
            var pages: [Bool] = []
            host.rootView = AnyView(
                ZStack {
                    Color(white: 0.75)
                    PlozziOSHeroPagingControls(
                        itemCount: 3, isEnabled: true, onPage: { pages.append($0) }
                    )
                }
                .ignoresSafeArea()
                .environment(\.plozziOSIsRunningOnMac, true)
                .environment(\.locale, Locale(identifier: "en_US"))
            )
            try await waitForHostedLayout(window)
            let buttons = descendants(window).compactMap { $0 as? PlozziOSHeroPagingUIButton }
            let previous = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier == "home-hero-previous" })
            let next = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier == "home-hero-next" })
            for button in [previous, next] {
                XCTAssertEqual(button.bounds.size, CGSize(width: 44, height: 64))
                XCTAssertTrue(button.point(inside: CGPoint(x: 0.5, y: 0.5), with: nil))
                XCTAssertTrue(button.point(inside: CGPoint(x: 43.5, y: 63.5), with: nil))
                XCTAssertTrue(button.isAccessibilityElement)
                XCTAssertTrue(button.accessibilityTraits.contains(.button))
                XCTAssertTrue(button.gestureRecognizers?.contains { $0 is UIHoverGestureRecognizer } == true)
            }
            XCTAssertEqual(previous.accessibilityLabel, "Previous")
            XCTAssertEqual(next.accessibilityLabel, "Next")
            let leftPoint = previous.convert(CGPoint(x: 22, y: 14), to: window)
            let rightPoint = next.convert(CGPoint(x: 22, y: 14), to: window)
            let idle = snapshot(window, name: "hero-hover-idle")
            let idlePixel = Int(try pixel(idle, at: leftPoint)[0])
            let hover = HeroHoverGestureFixture()
            hover.phase = .began
            previous.hoverChanged(hover)
            try await waitForHostedLayout(window)
            let hovered = snapshot(window, name: "hero-hover-enter")
            XCTAssertLessThan(Int(try pixel(hovered, at: leftPoint)[0]), idlePixel - 30)
            XCTAssertLessThanOrEqual(abs(Int(try pixel(hovered, at: rightPoint)[0]) - idlePixel), 2)

            previous.sendActions(for: .primaryActionTriggered)
            next.sendActions(for: .primaryActionTriggered)
            XCTAssertEqual(pages, [false, true])
            for ending in [UIGestureRecognizer.State.ended, .cancelled] {
                hover.phase = .began
                previous.hoverChanged(hover)
                hover.phase = ending
                previous.hoverChanged(hover)
                try await waitForHostedLayout(window)
                let exited = snapshot(window, name: "hero-hover-exit-\(ending.rawValue)")
                XCTAssertLessThanOrEqual(abs(Int(try pixel(exited, at: leftPoint)[0]) - idlePixel), 2)
            }
            previous.isEnabled = false
            hover.phase = .began
            previous.hoverChanged(hover)
            previous.sendActions(for: .primaryActionTriggered)
            try await waitForHostedLayout(window)
            XCTAssertEqual(pages, [false, true])
            let disabled = snapshot(window, name: "hero-hover-disabled")
            XCTAssertLessThanOrEqual(abs(Int(try pixel(disabled, at: leftPoint)[0]) - idlePixel), 2)
        }
    }

    func testMacHeroHoverUsesAnOpaqueBackgroundForAccessibilityPreferences() throws {
        let button = PlozziOSHeroPagingUIButton(frame: CGRect(x: 0, y: 0, width: 44, height: 64))
        let hover = HeroHoverGestureFixture()
        hover.phase = .began
        button.hoverChanged(hover)
        for (increasedContrast, reduceTransparency, alpha) in [
            (false, false, CGFloat(0.55)),
            (true, false, 1),
            (false, true, 1)
        ] {
            button.increasedContrast = increasedContrast
            button.reduceTransparency = reduceTransparency
            button.updateConfiguration()
            let color = try XCTUnwrap(button.configuration?.background.backgroundColor)
            XCTAssertEqual(color.cgColor.alpha, alpha, accuracy: 0.001)
        }
    }

    func testMacNavigationBackgroundKeepsArtworkClearAndNativeControlsVisible() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Scroll-edge effects require iOS 26.") }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let item = try await artworkItem()
        try await withWindow(
            item: item, size: scene.coordinateSpace.bounds.size, sizeClass: nil,
            insets: .zero, pull: PlozziOSHomeHeroPullModel()
        ) { window, host in
            for isRunningOnMac in [false, true, false] {
                host.rootView = AnyView(
                    MacNavigationBackgroundFixture()
                        .environment(\.plozziOSIsRunningOnMac, isRunningOnMac)
                        .environment(\.colorScheme, .dark)
                )
                try await waitForHostedLayout(window)
                let tabs = try XCTUnwrap(findController(UITabBarController.self, in: host))
                for sidebarHidden in [true, false] {
                    tabs.sidebar.isHidden = sidebarHidden
                    try await waitForHostedLayout(window)
                    let navigation = try XCTUnwrap(findController(UINavigationController.self, in: tabs))
                    let scroll = try XCTUnwrap(descendants(navigation.view).compactMap { $0 as? UIScrollView }
                        .first { $0.contentSize.height > $0.bounds.height })
                    XCTAssertEqual(scroll.topEdgeEffect.isHidden, isRunningOnMac)
                    XCTAssertFalse(scroll.bottomEdgeEffect.isHidden)
                    XCTAssertFalse(navigation.isNavigationBarHidden)
                    XCTAssertEqual(tabs.sidebar.isHidden, sidebarHidden)
                    let image = snapshot(window, name: "navigation-background-mac-\(isRunningOnMac)-sidebar-\(!sidebarHidden)")
                    let trailing = CGRect(x: image.size.width - 240, y: 0, width: 240, height: 150)
                    let controlImage = UIImage(
                        cgImage: try XCTUnwrap(image.cgImage?.cropping(to: trailing.applying(
                            CGAffineTransform(scaleX: image.scale, y: image.scale)
                        ))), scale: image.scale, orientation: .up
                    )
                    let controls = try HeroTextInk.frames(in: controlImage, terms: ["PROFILE"], darkTerms: ["PROFILE"])
                    let profile = try XCTUnwrap(controls["PROFILE"])
                    XCTAssertTrue(window.bounds.contains(profile.offsetBy(dx: trailing.minX, dy: 0)))
                    if isRunningOnMac {
                        let bar = navigation.navigationBar.convert(navigation.navigationBar.bounds, to: window)
                        let x = bar.minX + bar.width * 0.7
                        let top = try pixel(image, at: CGPoint(x: x, y: bar.midY))
                        let content = try pixel(image, at: CGPoint(x: x, y: bar.maxY + 120))
                        for channel in 0..<3 {
                            XCTAssertLessThan(
                                abs(Int(top[channel]) - Int(content[channel])), 10,
                                "The navigation area must not add a backdrop over the artwork."
                            )
                        }
                    }
                }
            }
        }
    }

    func testMacWideWindowsKeepTheArtworkTopAndActionsVisible() async throws {
        let item = try await artworkItem(marksTop: true)
        let sizes = [
            CGSize(width: 1_280, height: 720),
            CGSize(width: 1_440, height: 900),
            CGSize(width: 1_920, height: 1_080),
            CGSize(width: 2_560, height: 1_080)
        ]
        try await withWindow(
            item: item, size: sizes[0], sizeClass: .regular, insets: .zero,
            pull: PlozziOSHomeHeroPullModel(), isRunningOnMac: true, tracksWindowHeight: true,
            heroItems: [
                item,
                MediaItem(
                    id: "next-hero", title: "NEXT HERO", kind: .movie,
                    backdropURL: item.backdropURL, allowsTitleBasedMetadataMatching: false
                )
            ]
        ) { window, _ in
            for size in sizes + sizes.reversed() {
                window.frame = CGRect(origin: .zero, size: size)
                try await waitForHostedLayout(window)
                let image = snapshot(window, name: "mac-hero-\(Int(size.width))x\(Int(size.height))")
                let frames = try HeroTextInk.frames(
                    in: image, terms: ["Play", "Following row"], darkTerms: ["Play"]
                )
                let play = try XCTUnwrap(frames["Play"])
                XCTAssertGreaterThan(play.minY, 0)
                XCTAssertLessThan(play.maxY, size.height - HeroStageMetrics.minimumPeek)
                let followingRow = try XCTUnwrap(frames["Following row"])
                XCTAssertLessThan(followingRow.maxY, size.height)
                try assertTopMarker(image)
            }
        }
    }

    func testMacCarouselPreservesTheArtworkTopWhileSliding() async throws {
        let item = try await artworkItem(marksTop: true)
        let size = CGSize(width: 1_920, height: 1_080)
        try await withWindow(
            item: item, size: size, sizeClass: .regular, insets: .zero,
            pull: PlozziOSHomeHeroPullModel(), isRunningOnMac: true
        ) { window, host in
            let sidebar = PlozziOSSidebarGeometryModel()
            let trailer = HeroTrailerController()
            for (sliding, offset) in [(false, CGFloat(0)), (true, 0), (true, -100), (true, 100)] {
                host.rootView = AnyView(
                    ZStack(alignment: .top) {
                        Color.black
                        PlozziOSHomeStaticBackdrop(
                            item: item, style: .landscape, height: 600,
                            contentOffsetX: offset, showsTrailer: false, usesSlidingArtwork: sliding
                        )
                    }
                    .ignoresSafeArea()
                    .environment(sidebar)
                    .environment(trailer)
                    .environment(\.themePalette, .dark)
                    .environment(\.colorScheme, .dark)
                    .environment(\.plozziOSIsRunningOnMac, true)
                )
                try await waitForHostedLayout(window)
                try assertTopMarker(snapshot(window, name: "mac-carousel-\(sliding)-\(offset)"))
            }
        }
    }

    func testHeroCompositeSpansHorizontalSafeAreasWithoutMovingForeground() async throws {
        let item = try await artworkItem()
        for (size, sizeClass) in [
            (CGSize(width: 390, height: 844), UserInterfaceSizeClass.compact),
            (CGSize(width: 1024, height: 768), .regular)
        ] {
            for insets in [
                UIEdgeInsets.zero,
                UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 78),
                UIEdgeInsets(top: 0, left: 64, bottom: 0, right: 34)
            ] {
                let pull = PlozziOSHomeHeroPullModel()
                try await withWindow(item: item, size: size, sizeClass: sizeClass, insets: insets, pull: pull) {
                    window, host in
                    for distance in [CGFloat(0), 60] {
                        pull.update(distance)
                        try await waitForHostedLayout(window)
                        let image = snapshot(window, name: "hero-width-\(Int(size.width))-\(Int(insets.left))-\(Int(insets.right))-pull-\(Int(distance))")
                        try assertArtworkAtBothEdges(image)
                        let frames = try HeroTextInk.frames(in: image, terms: ["HERO", "Play"], darkTerms: ["Play"])
                        let safe = window.bounds.inset(by: host.view.safeAreaInsets)
                        for term in ["HERO", "Play"] {
                            let frame = try XCTUnwrap(frames[term], "Missing \(term)")
                            XCTAssertGreaterThanOrEqual(frame.minX, safe.minX)
                            XCTAssertLessThanOrEqual(frame.maxX, safe.maxX)
                        }
                    }
                }
            }
        }
    }

    func testNativeTabChromeKeepsArtworkBehindTheSideRail() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let item = try await artworkItem()
        let size = scene.coordinateSpace.bounds.size
        try await withWindow(
            item: item, size: size, sizeClass: nil, insets: .zero,
            pull: PlozziOSHomeHeroPullModel(), nativeTabs: true
        ) { window, _ in
            try await waitForHostedLayout(window)
            let image = snapshot(window, name: "native-hero-width-\(Int(size.width))x\(Int(size.height))")
            try assertArtworkAtBothEdges(image)
        }
    }

    private func artworkItem(marksTop: Bool = false) async throws -> MediaItem {
        let url = try XCTUnwrap(URL(string: "https://hero-width.invalid/\(UUID().uuidString).png"))
        let size = marksTop ? CGSize(width: 1_600, height: 900) : CGSize(width: 900, height: 1_200)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(red: 0.15, green: 0.75, blue: 0.95, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.25, green: 0.85, blue: 0.95, alpha: 1).setFill()
            for x in stride(from: 0, to: 900, by: 100) {
                context.fill(CGRect(x: x, y: 0, width: 20, height: 1200))
            }
            if marksTop {
                UIColor.magenta.setFill()
                context.fill(CGRect(x: 0, y: 0, width: size.width, height: 140))
            }
        }
        let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=86400"]
        ))
        cache.storeCachedResponse(
            CachedURLResponse(response: response, data: try XCTUnwrap(image.pngData())),
            for: URLRequest(url: url)
        )
        let decoded = await ArtworkImageCache.shared.image(for: url, variant: .heroBackdrop)
        XCTAssertNotNil(decoded)
        return MediaItem(
            id: UUID().uuidString, title: "HERO", kind: .movie,
            overview: "Artwork behind the native controls.",
            posterURL: url, backdropURL: url, allowsTitleBasedMetadataMatching: false
        )
    }

    private func withWindow(
        item: MediaItem, size: CGSize, sizeClass: UserInterfaceSizeClass?,
        insets: UIEdgeInsets, pull: PlozziOSHomeHeroPullModel, nativeTabs: Bool = false,
        isRunningOnMac: Bool = false,
        tracksWindowHeight: Bool = false,
        heroItems: [MediaItem]? = nil,
        onHeroPinnedItemsChanged: @escaping (Set<String>) -> Void = { _ in },
        exercise: (UIWindow, UIHostingController<AnyView>) async throws -> Void
    ) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "HeroWidth-\(UUID().uuidString)"))
        let app = PlozziOSAppModel(
            accountStore: AccountStore(secureStore: InMemorySecureStore()),
            profileStore: ProfileStore(defaults: defaults)
        )
        app.settings.heroBackground.settings.homeTrailerEnabled = false
        let sidebar = PlozziOSSidebarGeometryModel()
        let root = HomeHeroWidthFixture(
            items: heroItems ?? [item], pull: pull, nativeTabs: nativeTabs, sidebar: sidebar,
            tracksWindowHeight: tracksWindowHeight, onPinnedItemsChanged: onHeroPinnedItemsChanged
        )
            .environment(app)
            .environment(sidebar)
            .environment(HeroTrailerController())
            .environment(\.themePalette, .dark)
            .environment(\.colorScheme, .dark)
            .environment(\.plozzMetrics, PlozziOSMediaLayout.metrics(
                density: .standard, dynamicTypeSize: .large, isRunningOnMac: isRunningOnMac
            ))
            .environment(\.plozziOSHeroContainerHeight, size.height)
            .environment(\.plozziOSIsRunningOnMac, isRunningOnMac)
            .environment(\.scenePhase, .active)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.dynamicTypeSize, .large)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: AnyView(root))
        if let sizeClass {
            host.safeAreaRegions = []
            host.rootView = AnyView(root.environment(\.horizontalSizeClass, sizeClass))
        }
        host.additionalSafeAreaInsets = insets
        host.overrideUserInterfaceStyle = .dark
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitForHostedLayout(window)
        try await exercise(window, host)
    }

    private func snapshot(_ window: UIWindow, name: String) -> UIImage {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
    }

    private func findController<T: UIViewController>(_ type: T.Type, in controller: UIViewController) -> T? {
        (controller as? T) ?? controller.children.lazy.compactMap { self.findController(type, in: $0) }.first
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func pixel(_ image: UIImage, at point: CGPoint) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage)
        let sample = try XCTUnwrap(cgImage.cropping(to: CGRect(
            x: point.x * image.scale, y: point.y * image.scale, width: 1, height: 1
        )))
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return pixel
    }

    private func pagingControlInk(
        in image: UIImage, region: CGRect
    ) throws -> (bounds: CGRect?, pixels: Int, peak: UInt8) {
        let crop = try XCTUnwrap(image.cgImage?.cropping(to: region.applying(
            CGAffineTransform(scaleX: image.scale, y: image.scale)
        )))
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        var bounds = CGRect.null
        var pixels = 0
        var peak: UInt8 = 0
        for y in 0..<crop.height {
            for x in 0..<crop.width where bytes[(y * crop.width + x) * 4] > 80 {
                pixels += 1
                peak = max(peak, bytes[(y * crop.width + x) * 4])
                bounds = bounds.union(CGRect(
                    x: region.minX + CGFloat(x) / image.scale,
                    y: region.minY + CGFloat(y) / image.scale,
                    width: 1 / image.scale, height: 1 / image.scale
                ))
            }
        }
        return (bounds.isNull ? nil : bounds, pixels, peak)
    }

    private func assertArtworkAtBothEdges(
        _ image: UIImage, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let cgImage = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: cgImage.width, height: cgImage.height,
                bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        }
        // Below the status controls, above hero text, and outside the rail's buttons.
        for x in [CGFloat(3), image.size.width - 3] {
            let y = image.size.height * 0.32
            let offset = (Int(y * image.scale) * cgImage.width + Int(x * image.scale)) * 4
            XCTAssertGreaterThan(Int(bytes[offset + 2]), 120, "Missing artwork at x=\(x)", file: file, line: line)
            XCTAssertGreaterThan(
                Int(bytes[offset + 2]) - Int(bytes[offset]), 60,
                "The edge must contain the blue artwork, not the page background.", file: file, line: line
            )
        }
    }

    private func assertTopMarker(_ image: UIImage) throws {
        let cgImage = try XCTUnwrap(image.cgImage)
        let x = Int(image.size.width * 0.8 * image.scale)
        let y = Int(80 * image.scale)
        let marker = try XCTUnwrap(cgImage.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(marker, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertGreaterThan(pixel[0], 180, "The top-of-art marker must survive a wide crop.")
        XCTAssertLessThan(pixel[1], 70)
        XCTAssertGreaterThan(pixel[2], 180)
    }
}

private final class HeroHoverGestureFixture: UIHoverGestureRecognizer {
    var phase: UIGestureRecognizer.State = .possible
    override var state: UIGestureRecognizer.State {
        get { phase }
        set { phase = newValue }
    }
}

@available(iOS 26.0, *)
private struct MacNavigationBackgroundFixture: View {
    var body: some View {
        TabView {
            Tab("Home", systemImage: "house") {
                NavigationStack {
                    ScrollView {
                        Color(uiColor: .cyan).frame(height: 3_000)
                    }
                    .ignoresSafeArea()
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(action: {}) {
                                Text(verbatim: "PROFILE").font(.title2).foregroundStyle(.black)
                            }
                        }
                    }
                }
            }
            Tab("Search", systemImage: "magnifyingglass", role: .search) { Text("Search") }
        }
        .tabViewStyle(.sidebarAdaptable)
        .scrollEdgeEffectStyle(.hard, for: .top)
        .modifier(PlozziOSMacNavigationBackground())
    }
}

private struct HomeHeroWidthFixture: View {
    let items: [MediaItem]
    let pull: PlozziOSHomeHeroPullModel
    let nativeTabs: Bool
    let sidebar: PlozziOSSidebarGeometryModel
    var tracksWindowHeight = false
    var onPinnedItemsChanged: (Set<String>) -> Void = { _ in }

    var body: some View {
        if nativeTabs {
            TabView {
                Tab("Home", systemImage: "house") { home }
                Tab("Search", systemImage: "magnifyingglass", role: .search) { Text("Search") }
            }
            .tabViewStyle(.sidebarAdaptable)
            .background {
                PlozziOSHomeSidebarOverlapProbe(enabled: true, geometryModel: sidebar)
                    .frame(width: 0, height: 0)
            }
        } else {
            home
        }
    }

    @ViewBuilder
    private var home: some View {
        if tracksWindowHeight {
            homeContent.plozziOSTracksHeroContainerHeight()
        } else {
            homeContent
        }
    }

    private var homeContent: some View {
        NavigationStack {
            PlozziOSHomeScrollView(heroActive: true) {
                PlozziOSHomeHeroCarousel(
                    items: items, autoAdvance: false, autoAdvanceSeconds: 30,
                    onPlay: { _ in }, onPinnedItemsChanged: onPinnedItemsChanged, pullModel: pull
                )
            } rows: {
                Text("Following row")
                Color.clear.frame(height: 1200)
            }
            .background(Color.black.ignoresSafeArea())
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") {}
                }
            }
        }
    }
}
#endif
