#if os(iOS)
import CoreModels
@testable import CoreUI
import FeatureAuth
import FeatureHomeCore
import SwiftUI
import UIKit
import XCTest
@testable import AppShelliOS

@MainActor
final class HomeHeroFullWidthPresentationTests: XCTestCase {
    func testColdHeroPreviewSurvivesRebuildingBeforeFullResolution() async throws {
        for landscape in [false, true] {
            let url = try XCTUnwrap(URL(string: "https://hero-preview.invalid/\(UUID()).png"))
            let artwork = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 600)).image { context in
                UIColor.blue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
            }
            let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=86400"]
            ))
            cache.storeCachedResponse(
                CachedURLResponse(response: response, data: try XCTUnwrap(artwork.pngData())),
                for: URLRequest(url: url)
            )
            defer { cache.removeCachedResponse(for: URLRequest(url: url)) }
            let preview = await ArtworkImageCache.shared.image(for: url, variant: .heroPreview)
            XCTAssertNotNil(preview)
            XCTAssertNil(ArtworkImageCache.shared.cachedImage(for: url, variant: .heroBackdrop))
            let identity = UUID().uuidString
            let policy = ArtworkPresentationPolicy(area: .home, settings: ArtworkSettings(preference: .online))
            var rebuilt: UIImage?
            func picture(onResolve: ((ArtworkReference?) -> Void)? = nil) -> some View {
                FallbackAsyncImage(
                    references: [], prefersLandscape: landscape, maxAspectRatio: 3,
                    variant: .heroBackdrop, previewVariant: .heroPreview,
                    artworkPolicy: policy, asyncFallbackURL: { url },
                    onResolveReference: onResolve, pinIdentity: identity
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: { Color.red }
                .showingPlaceholderWhileLoading(true)
                .frame(width: 200, height: 150)
                .clipped()
            }
            let item = MediaItem(id: identity, title: "Preview", kind: .movie, allowsTitleBasedMetadataMatching: false)
            try await withWindow(
                item: item, size: CGSize(width: 390, height: 844), sizeClass: .compact,
                insets: .zero, pull: PlozziOSHomeHeroPullModel()
            ) { window, host in
                host.rootView = AnyView(picture { _ in
                    guard rebuilt == nil else { return }
                    // Capture the replacement synchronously, before the full-quality
                    // await can finish. This is the carousel's landing-frame boundary.
                    rebuilt = ImageRenderer(content: picture()).uiImage
                })
                let deadline = ContinuousClock.now + .seconds(3)
                while rebuilt == nil, ContinuousClock.now < deadline {
                    try await waitForHostedLayout(window)
                }
                let image = try XCTUnwrap(rebuilt)
                let attachment = XCTAttachment(image: image)
                attachment.name = "cold-preview-rebuild-\(landscape)"
                attachment.lifetime = .keepAlways
                add(attachment)
                let center = try pixel(image, at: CGPoint(x: 100, y: 75))
                XCTAssertGreaterThan(center[2], 230, "A rebuilt hero must keep its already displayed blue preview.")
                XCTAssertLessThan(center[0], 20, "The red loading background must never replace the preview.")
            }
        }
    }

    func testSlidingAndIdleHeroReuseTheSameResolvedArtworkIdentity() async throws {
        let artwork = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 600)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
        }
        for style in [HeroArtworkStyle.compactPortrait, .landscape] {
            let item = MediaItem(
                id: UUID().uuidString, title: "Hero", kind: .movie, allowsTitleBasedMetadataMatching: false
            )
            let policy = ArtworkPresentationPolicy(
                area: .home, settings: ArtworkSettings(preference: .online), placement: .homeHero
            )
            let key = ArtworkResolveKey.make(
                references: [], variant: .heroBackdrop, maxAspectRatio: 3,
                pinIdentity: PlozziOSHeroArtworkFallback.cacheIdentity("home:\(item.id)", style: style),
                providerPolicyIdentity: policy.identity, prefersLandscape: style != .compactPortrait
            )
            let reference = ArtworkReference.remote(try XCTUnwrap(URL(string: "https://prepared.invalid/\(UUID()).png")))
            ArtworkSeedMemo.store(artwork, reference: reference, for: key)
            try await withWindow(
                item: item, size: CGSize(width: 600, height: 844), sizeClass: .regular,
                insets: .zero, pull: PlozziOSHomeHeroPullModel()
            ) { window, host in
                for sliding in [true, false, true] {
                    host.rootView = AnyView(
                        PlozziOSHomeStaticBackdrop(
                            item: item, style: style, height: 400,
                            showsTrailer: false, usesSlidingArtwork: sliding
                        )
                        .environment(PlozziOSSidebarGeometryModel())
                        .environment(HeroTrailerController())
                        .environment(\.plozzArtworkArea, .home)
                        .environment(\.plozzArtworkSettings, policy.settings)
                        .environment(\.themePalette, .dark)
                        .frame(maxHeight: .infinity, alignment: .top)
                    )
                    try await waitForHostedLayout(window)
                    let image = snapshot(window, name: "hero-identity-\(style)-\(sliding)")
                    let center = try pixel(image, at: CGPoint(x: 300, y: 100))
                    XCTAssertGreaterThan(Int(center[2]) - Int(center[0]), 200,
                                         "Sliding and idle must reuse the same already-selected image.")
                }
            }
        }
    }

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

    func testHomeAndMacNavigationBackgroundKeepArtworkClearAndNativeControlsVisible() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Scroll-edge effects require iOS 26.") }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let item = try await artworkItem()
        try await withWindow(
            item: item, size: scene.coordinateSpace.bounds.size, sizeClass: nil,
            insets: .zero, pull: PlozziOSHomeHeroPullModel()
        ) { window, host in
            for (isRunningOnMac, hidesTopBackdrop) in [(false, false), (false, true), (true, false), (false, false)] {
                host.rootView = AnyView(
                    MacNavigationBackgroundFixture(hidesTopBackdrop: hidesTopBackdrop)
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
                    XCTAssertEqual(scroll.topEdgeEffect.isHidden,
                                   hidesTopBackdrop || isRunningOnMac || UIAccessibility.isReduceTransparencyEnabled)
                    XCTAssertEqual(scroll.bottomEdgeEffect.isHidden, UIAccessibility.isReduceTransparencyEnabled)
                    XCTAssertFalse(navigation.isNavigationBarHidden)
                    XCTAssertEqual(tabs.sidebar.isHidden, sidebarHidden)
                    let image = snapshot(window, name: "navigation-background-home-\(hidesTopBackdrop)-mac-\(isRunningOnMac)-sidebar-\(!sidebarHidden)")
                    let trailing = CGRect(x: image.size.width - 240, y: 0, width: 240, height: 150)
                    let controlImage = UIImage(
                        cgImage: try XCTUnwrap(image.cgImage?.cropping(to: trailing.applying(
                            CGAffineTransform(scaleX: image.scale, y: image.scale)
                        ))), scale: image.scale, orientation: .up
                    )
                    let controls = try HeroTextInk.frames(in: controlImage, terms: ["PROFILE"])
                    let profile = try XCTUnwrap(controls["PROFILE"])
                    XCTAssertTrue(window.bounds.contains(profile.offsetBy(dx: trailing.minX, dy: 0)))
                    if hidesTopBackdrop || isRunningOnMac || UIAccessibility.isReduceTransparencyEnabled {
                        let bar = navigation.navigationBar.convert(navigation.navigationBar.bounds, to: window)
                        let x = bar.minX + 4
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

    func testReducedTransparencyKeepsPhoneNavigationEdgesClearWithoutHidingControls() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Scroll-edge effects require iOS 26.") }
        if let expected = ProcessInfo.processInfo.environment["PLOZZ_EXPECT_REDUCED_TRANSPARENCY"] {
            XCTAssertEqual(UIAccessibility.isReduceTransparencyEnabled, expected == "1")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let item = try await artworkItem()
        try await withWindow(
            item: item, size: scene.coordinateSpace.bounds.size, sizeClass: nil,
            insets: .zero, pull: PlozziOSHomeHeroPullModel()
        ) { window, host in
            for reduced in [false, true, false] {
                host.rootView = AnyView(
                    MacNavigationBackgroundFixture()
                        .environment(\.plozziOSIsRunningOnMac, false)
                        .environment(\.plozzReduceTransparency, reduced)
                        .environment(\.colorScheme, .dark)
                )
                try await waitForHostedLayout(window)
                let tabs = try XCTUnwrap(findController(UITabBarController.self, in: host))
                let navigation = try XCTUnwrap(findController(UINavigationController.self, in: tabs))
                let scroll = try XCTUnwrap(descendants(navigation.view).compactMap { $0 as? UIScrollView }
                    .first { $0.contentSize.height > $0.bounds.height })
                let hidesEdgeEffects = reduced || UIAccessibility.isReduceTransparencyEnabled
                XCTAssertEqual(scroll.topEdgeEffect.isHidden, hidesEdgeEffects)
                XCTAssertEqual(scroll.bottomEdgeEffect.isHidden, hidesEdgeEffects)
                XCTAssertFalse(navigation.isNavigationBarHidden)
                XCTAssertFalse(tabs.tabBar.isHidden)
                for offset: CGFloat in [0, 400] {
                    scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                    try await waitForHostedLayout(window)
                    let image = snapshot(
                        window,
                        name: "phone-navigation-system-\(UIAccessibility.isReduceTransparencyEnabled)-app-\(reduced)-scroll-\(offset)"
                    )
                    if hidesEdgeEffects {
                        let reference = try pixel(image, at: CGPoint(x: 4, y: window.bounds.midY))
                        let bar = navigation.navigationBar.convert(navigation.navigationBar.bounds, to: window)
                        for y in [bar.midY, window.bounds.height - 8] {
                            let actual = try pixel(image, at: CGPoint(x: 4, y: y))
                            for channel in 0..<3 {
                                XCTAssertLessThan(abs(Int(actual[channel]) - Int(reference[channel])), 10,
                                                  "Native controls must not add full-width opaque edge bands.")
                            }
                        }
                    }
                }
            }
        }
    }

    private struct OpaqueNavigationControllerFixture: UIViewControllerRepresentable {
        let navigation: UINavigationController
        func makeUIViewController(context: Context) -> UINavigationController { navigation }
        func updateUIViewController(_ controller: UINavigationController, context: Context) {}
    }

    private final class NavigationDelegateFixture: NSObject, UINavigationControllerDelegate {}

    private func registerDetailProvider(_ provider: SeriesHeaderMobileProvider, in app: PlozziOSAppModel) throws {
        let session = provider.session
        let account = Account(
            id: try XCTUnwrap(provider.show.sourceAccountID), server: session.server,
            userID: session.userID, userName: session.userName, deviceID: session.deviceID
        )
        app.accountsProviders.registry.register(.jellyfin) { _ in provider }
        try app.accountsProviders.accountStore.add(account, token: "fixture")
        app.accountsProviders.reloadAccounts()
        XCTAssertNotNil(app.accountsProviders.provider(forAccountID: account.id))
    }

    func testOpaqueNavigationSelectedLabelContrast() {
        for palette in [ThemePalette.dark, .light, .pureBlack] {
            for gradient in [true, false] {
                let surface = OpaqueNavigationSurface(palette: palette, gradientEnabled: gradient, bottom: true)
                var environment = EnvironmentValues()
                environment.colorScheme = palette.isLight ? .light : .dark
                func luminance(_ color: Color) -> Double {
                    let value = color.resolve(in: environment)
                    let channels = [Double(value.red), Double(value.green), Double(value.blue)].map {
                        $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
                    }
                    return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
                }
                let foreground = luminance(surface.selectionForeground)
                let background = luminance(surface.selection)
                XCTAssertGreaterThanOrEqual((max(foreground, background) + 0.05)
                                            / (min(foreground, background) + 0.05), 4.5,
                                           "Light: \(palette.isLight), gradient: \(gradient)")
            }
        }
    }

    func testOpaqueSettingsGroupsKeepPageGradientAndRejectUnderlyingContent() async throws {
        let item = try await artworkItem()
        try await withWindow(
            item: item, size: CGSize(width: 402, height: 874), sizeClass: .compact,
            insets: .zero, pull: PlozziOSHomeHeroPullModel()
        ) { window, host in
            var frames: [Int: CGRect] = [:]
            for (name, palette, dialog) in [
                ("dark", ThemePalette.dark, false), ("light", .light, false),
                ("black", .pureBlack, false), ("sheet", .dark, true)
            ] {
                for gradient in [true, false] {
                    var reference: [[UInt8]] = []
                    var opaque: [[UInt8]] = []
                    for (mode, reduced, underlay) in [
                        ("on", false, Color.clear), ("off", true, .clear),
                        ("red", true, .red), ("blue", true, .blue), ("restored", false, .clear)
                    ] {
                        host.rootView = AnyView(
                            VStack(spacing: 100) {
                                ForEach(0..<3) { index in
                                    Color.clear.frame(height: 110)
                                        .settingsGroupSurface(cornerRadius: 16)
                                        .background(underlay)
                                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                                            frames[index] = $0
                                        }
                                }
                            }
                            .padding(24)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .settingsPageSurface(horizontalInset: 0)
                            .environment(\.plozzDialogBackgroundOwned, dialog)
                            .environment(\.themePalette, palette)
                            .environment(\.colorScheme, palette.isLight ? .light : .dark)
                            .environment(\.gradientBackgroundsEnabled, gradient)
                            .environment(\.plozzReduceTransparency, reduced)
                        )
                        try await waitForHostedLayout(window)
                        try await Task.sleep(for: .seconds(1))
                        let image = snapshot(window, name: "settings-surfaces-\(name)-gradient-\(gradient)-\(mode)")
                        var samples: [[UInt8]] = []
                        for index in 0..<3 {
                            let frame = try XCTUnwrap(frames[index])
                            samples.append(try pixel(image, at: CGPoint(x: frame.midX, y: frame.midY)))
                        }
                        if mode == "on" {
                            reference = samples
                        } else if mode == "off" || mode == "restored" {
                            for index in 0..<3 {
                                for channel in 0..<3 {
                                    XCTAssertEqual(Int(samples[index][channel]), Int(reference[index][channel]),
                                                   accuracy: 3, "\(name), gradient \(gradient), \(mode), group \(index)")
                                }
                            }
                            if mode == "off" { opaque = samples }
                        } else {
                            XCTAssertEqual(samples, opaque, "Opaque settings must not reveal content underneath.")
                        }
                    }
                }
            }
        }
    }

    func testAppReducedTransparencyUsesOpaqueNavigationButtonsAndRestoresGlass() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Native glass requires iOS 26.") }
        XCTAssertFalse(UIAccessibility.isReduceTransparencyEnabled, "This regression requires OS Reduce Transparency off.")
        let item = try await artworkItem()
        let provider = SeriesHeaderMobileProvider(artworkURL: item.posterURL)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "NativeChrome-\(UUID().uuidString)"))
        let app = PlozziOSAppModel(
            accountStore: AccountStore(secureStore: InMemorySecureStore()),
            profileStore: ProfileStore(defaults: defaults)
        )
        try registerDetailProvider(provider, in: app)
        app.settings.heroBackground.settings.detailMode = .off
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        try await withWindow(
            item: item, size: scene.coordinateSpace.bounds.size, sizeClass: nil,
            insets: .zero, pull: PlozziOSHomeHeroPullModel()
        ) { window, host in
            var originalTop: UIViewController?
            for (reduced, scheme) in [
                (false, ColorScheme.dark), (true, .dark), (true, .light), (false, .light)
            ] {
                host.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
                host.rootView = AnyView(
                    PushedDetailTransparencyFixture(app: app, provider: provider)
                    .plozzOpaqueNavigationChrome()
                    .environment(app)
                    .environment(HeroTrailerController())
                    .environment(PlozziOSSidebarGeometryModel())
                    .environment(\.horizontalSizeClass, .compact)
                    .environment(\.plozziOSHeroContainerHeight, window.bounds.height)
                    .environment(\.themePalette, scheme == .dark ? .dark : .light)
                    .environment(\.colorScheme, scheme)
                    .environment(\.plozzReduceTransparency, reduced)
                )
                try await Task.sleep(for: .seconds(2))
                try await waitForHostedLayout(window)
                let navigation = try XCTUnwrap(findController(UINavigationController.self, in: host))
                let top = try XCTUnwrap(navigation.topViewController)
                XCTAssertEqual(navigation.viewControllers.count, 2)
                if let originalTop { XCTAssertTrue(top === originalTop, "Appearance must not recreate navigation.") }
                originalTop = top
                let backImage = navigation.navigationBar.backItem?.backBarButtonItem?
                    .backButtonBackgroundImage(for: .normal, barMetrics: .default)
                XCTAssertEqual(backImage != nil, reduced)
                let current = top.navigationItem
                let buttons = (current.rightBarButtonItems ?? []) + current.trailingItemGroups.flatMap(\.barButtonItems)
                XCTAssertFalse(buttons.isEmpty)
                let rendered = snapshot(window, name: "app-liquid-glass-\(reduced ? "off" : "on")-\(scheme)")
                let barFrame = navigation.navigationBar.convert(navigation.navigationBar.bounds, to: window)
                let backSurface = try pixel(rendered, at: CGPoint(x: 38, y: barFrame.midY - 14))
                if reduced {
                    XCTAssertLessThan(abs(Int(backSurface[2]) - Int(backSurface[0])), 15)
                } else {
                    XCTAssertGreaterThan(Int(backSurface[2]) - Int(backSurface[0]), 20,
                                         "Restoring glass must clear the rendered Back background, not only its appearance property.")
                    for (index, controller) in navigation.viewControllers.enumerated() {
                        let item = controller.navigationItem
                        for (name, appearance) in [
                            ("standard", item.standardAppearance), ("scroll", item.scrollEdgeAppearance),
                            ("compact", item.compactAppearance), ("compactScroll", item.compactScrollEdgeAppearance)
                        ] {
                            XCTAssertNil(appearance?.backButtonAppearance.normal.backgroundImage, "\(index): \(name)")
                        }
                    }
                }
                for button in buttons {
                    XCTAssertEqual(button.hidesSharedBackground, reduced)
                    let custom = try XCTUnwrap(button.customView)
                    if reduced {
                        XCTAssertEqual(custom.backgroundColor?.cgColor.alpha, 1)
                        XCTAssertGreaterThanOrEqual(custom.bounds.width, 44)
                        XCTAssertGreaterThanOrEqual(custom.bounds.height, 44)
                        let frame = custom.convert(custom.bounds, to: window)
                        let surface = try pixel(rendered, at: CGPoint(x: frame.midX, y: frame.minY + 5))
                        XCTAssertLessThan(abs(Int(surface[2]) - Int(surface[0])), 15,
                                          "The blue artwork must not tint the opaque toolbar surface.")
                    } else {
                        XCTAssertNotEqual(custom.backgroundColor?.cgColor.alpha, 1)
                    }
                }
            }
        }
    }

    func testOpaqueToolbarGroupsPreserveActionsAndRestoreOriginalGrouping() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Native glass requires iOS 26.") }
        let item = try await artworkItem()
        let page = UIViewController()
        page.view.backgroundColor = .cyan
        let navigation = UINavigationController(rootViewController: page)
        let delegate = NavigationDelegateFixture()
        navigation.delegate = delegate
        var activationCount = 0
        let control = UIButton(type: .system, primaryAction: UIAction(title: "Action") { _ in
            activationCount += 1
        })
        control.layer.borderColor = UIColor.red.cgColor
        control.layer.borderWidth = 2
        let actionItem = UIBarButtonItem(customView: control)
        let menu = UIMenu(children: [UIAction(title: "Menu action") { _ in }])
        let menuItem = UIBarButtonItem(title: "Menu", menu: menu)
        let originalMenu = menuItem.menu
        let originalGroup = UIBarButtonItemGroup(barButtonItems: [actionItem, menuItem], representativeItem: nil)
        page.navigationItem.trailingItemGroups = [originalGroup]
        try await withWindow(
            item: item, size: CGSize(width: 402, height: 874), sizeClass: .compact,
            insets: .zero, pull: PlozziOSHomeHeroPullModel()
        ) { window, host in
            for reduced in [true, false, true, false] {
                host.rootView = AnyView(
                    OpaqueNavigationControllerFixture(navigation: navigation)
                        .plozzOpaqueNavigationChrome()
                        .environment(\.themePalette, .dark)
                        .environment(\.plozzReduceTransparency, reduced)
                )
                try await waitForHostedLayout(window)
                try await Task.sleep(for: .milliseconds(300))
                XCTAssertEqual(page.navigationItem.trailingItemGroups.count, reduced ? 2 : 1)
                XCTAssertTrue(navigation.delegate === delegate, "Appearance must not take over navigation delegation.")
                XCTAssertTrue(actionItem.customView === control)
                XCTAssertTrue(menuItem.menu === originalMenu)
                XCTAssertEqual(actionItem.hidesSharedBackground, reduced)
                XCTAssertEqual(menuItem.hidesSharedBackground, reduced)
                control.sendActions(for: .primaryActionTriggered)
                if !reduced {
                    XCTAssertEqual(control.layer.borderColor, UIColor.red.cgColor)
                    XCTAssertEqual(control.layer.borderWidth, 2)
                    XCTAssertTrue(page.navigationItem.trailingItemGroups.first === originalGroup)
                    XCTAssertEqual(originalGroup.barButtonItems, [actionItem, menuItem])
                }
            }
            XCTAssertEqual(activationCount, 4)
            host.rootView = AnyView(
                OpaqueNavigationControllerFixture(navigation: navigation)
                    .plozzOpaqueNavigationChrome()
                    .environment(\.themePalette, .dark)
                    .environment(\.plozzReduceTransparency, true)
            )
            try await waitForHostedLayout(window)
            let added = UIBarButtonItem(customView: UIButton(type: .system))
            let replacement = UIBarButtonItemGroup(barButtonItems: [added], representativeItem: nil)
            page.navigationItem.trailingItemGroups = [replacement]
            try await waitForHostedLayout(window)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertTrue(added.hidesSharedBackground, "Toolbar items added after presentation need the same fallback.")
            host.rootView = AnyView(
                OpaqueNavigationControllerFixture(navigation: navigation)
                    .plozzOpaqueNavigationChrome()
                    .environment(\.themePalette, .dark)
                    .environment(\.plozzReduceTransparency, false)
            )
            try await waitForHostedLayout(window)
            XCTAssertFalse(added.hidesSharedBackground)
            XCTAssertTrue(page.navigationItem.trailingItemGroups.first === replacement,
                          "Restoring glass must not restore an outdated toolbar.")
        }
    }

    func testOpaqueTabSurfaceDoesNotSampleItsBackground() async throws {
        let item = try await artworkItem()
        var samples: [[UInt8]] = []
        try await withWindow(
            item: item, size: CGSize(width: 402, height: 874), sizeClass: .compact,
            insets: .zero, pull: PlozziOSHomeHeroPullModel()
        ) { window, host in
            for (name, background) in [("red", Color.red), ("blue", Color.blue)] {
                host.rootView = AnyView(
                    background.ignoresSafeArea()
                        .overlay(alignment: .bottom) {
                            PlozzOpaqueTabBar(items: [0, 1, 2], selection: .constant(0)) {
                                Label(["Home", "Downloads", "Search"][$0],
                                      systemImage: ["house", "arrow.down.circle", "magnifyingglass"][$0])
                            }
                            .accessibilityIdentifier("opaque-tab-surface")
                        }
                        .environment(\.themePalette, .dark)
                )
                try await waitForHostedLayout(window)
                let image = snapshot(window, name: "opaque-tabs-over-\(name)")
                let sample = try pixel(image, at: CGPoint(
                    x: window.bounds.midX,
                    y: window.bounds.height - window.safeAreaInsets.bottom - 12
                ))
                samples.append(sample)
                XCTAssertLessThan(abs(Int(sample[0]) - Int(sample[2])), 15)
            }
        }
        XCTAssertEqual(samples[0], samples[1], "Changing the page must not change the opaque tab surface.")
    }

    func testPushedSeriesDetailArtworkReachesTheTopWithReducedTransparency() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Scroll-edge effects require iOS 26.") }
        let item = try await artworkItem()
        let provider = SeriesHeaderMobileProvider(artworkURL: item.posterURL)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DetailTransparency-\(UUID().uuidString)"))
        let app = PlozziOSAppModel(
            accountStore: AccountStore(secureStore: InMemorySecureStore()),
            profileStore: ProfileStore(defaults: defaults)
        )
        try registerDetailProvider(provider, in: app)
        app.settings.heroBackground.settings.detailMode = .off
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        try await withWindow(
            item: item, size: scene.coordinateSpace.bounds.size, sizeClass: nil,
            insets: .zero, pull: PlozziOSHomeHeroPullModel()
        ) { window, host in
            for scheme in [ColorScheme.dark, .light] {
                for reduced in [false, true] {
                    host.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
                    host.rootView = AnyView(
                        TabView {
                            Tab("Home", systemImage: "house") {
                                PushedDetailTransparencyFixture(app: app, provider: provider)
                            }
                            Tab("Search", systemImage: "magnifyingglass", role: .search) { Text("Search") }
                        }
                        .modifier(PlozziOSNavigationBackground())
                        .environment(app)
                        .environment(HeroTrailerController())
                        .environment(PlozziOSSidebarGeometryModel())
                        .environment(\.horizontalSizeClass, .compact)
                        .environment(\.plozziOSHeroContainerHeight, window.bounds.height)
                        .environment(\.themePalette, scheme == .dark ? .dark : .light)
                        .environment(\.colorScheme, scheme)
                        .environment(\.gradientBackgroundsEnabled, true)
                        .environment(\.plozzReduceTransparency, reduced)
                    )
                    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
                    var image: UIImage
                    repeat {
                        try await waitForHostedLayout(window)
                        image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                        }
                        let top = try pixel(image, at: CGPoint(x: 8, y: 8))
                        if Int(top[2]) - Int(top[0]) > 50 { break }
                    } while ContinuousClock.now < deadline
                    image = snapshot(window, name: "series-detail-\(scheme)-reduced-\(reduced)")
                    for y: CGFloat in [8, 70, 120] {
                        let top = try pixel(image, at: CGPoint(x: 8, y: y))
                        XCTAssertGreaterThan(Int(top[2]) - Int(top[0]), 50,
                                             "The actual detail artwork must extend behind the native navigation.")
                    }
                    let tabs = try XCTUnwrap(findController(UITabBarController.self, in: host))
                    XCTAssertFalse(tabs.tabBar.isHidden)
                    let navigation = try XCTUnwrap(findController(UINavigationController.self, in: tabs))
                    XCTAssertEqual(navigation.viewControllers.count, 2, "Exercise a pushed page, not the tab's root.")
                }
            }
        }
    }

    func testReducedTransparencyScrollFadeProtectsStatusTextOnlyAfterScrolling() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Scroll-edge effects require iOS 26.") }
        let item = try await artworkItem()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        try await withWindow(
            item: item, size: scene.coordinateSpace.bounds.size, sizeClass: .compact,
            insets: .zero, pull: PlozziOSHomeHeroPullModel()
        ) { window, host in
            for scheme in [ColorScheme.dark, .light] {
                for reduced in [false, true] {
                    host.rootView = AnyView(
                        NavigationStack {
                            ScrollView {
                                Color.blue.frame(height: 2400)
                            }
                            .ignoresSafeArea()
                            .modifier(PlozziOSReducedTransparencyScrollFade())
                            .scrollEdgeEffectHidden(true, for: .top)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbarBackground(.hidden, for: .navigationBar)
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("Profile", action: {})
                                }
                            }
                        }
                        .modifier(PlozziOSNavigationBackground())
                        .environment(\.themePalette, scheme == .dark ? .dark : .light)
                        .environment(\.colorScheme, scheme)
                        .environment(\.plozzReduceTransparency, reduced)
                    )
                    try await waitForHostedLayout(window)
                    let scroll = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UIScrollView }.first)
                    for offset: CGFloat in [0, 300, 0] {
                        scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                        try await waitForHostedLayout(window)
                        let image = snapshot(window, name: "status-fade-\(scheme)-\(reduced)-\(offset)")
                        let top = try pixel(image, at: CGPoint(x: 8, y: 8))
                        if offset > 0 && (reduced || UIAccessibility.isReduceTransparencyEnabled) {
                            XCTAssertLessThan(abs(Int(top[2]) - Int(top[0])), 20,
                                              "Scrolled artwork must not compete with status text.")
                        } else {
                            XCTAssertGreaterThan(Int(top[2]) - Int(top[0]), 100,
                                                 "Do not cover artwork at rest or override normal system chrome.")
                        }
                        let body = try pixel(image, at: CGPoint(x: 8, y: 200))
                        XCTAssertGreaterThan(Int(body[2]) - Int(body[0]), 100)
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

    func testNativeTopTabsKeepTheHeroFullWidth() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let item = try await artworkItem()
        let size = scene.coordinateSpace.bounds.size
        try await withWindow(
            item: item, size: size, sizeClass: nil, insets: .zero,
            pull: PlozziOSHomeHeroPullModel(), nativeTabs: true
        ) { window, host in
            let tabs = try XCTUnwrap(findController(UITabBarController.self, in: host))
            tabs.sidebar.isHidden = true
            try await waitForHostedLayout(window)
            XCTAssertTrue(tabs.sidebar.isHidden)
            let image = snapshot(window, name: "native-hero-width-\(Int(size.width))x\(Int(size.height))")
            for x in [CGFloat(3), image.size.width - 3] {
                let edge = try pixel(image, at: CGPoint(x: x, y: 150))
                XCTAssertGreaterThan(Int(edge[2]), 120, "The top-tab hero must reach both window edges.")
                XCTAssertGreaterThan(Int(edge[2]) - Int(edge[0]), 60)
            }
        }
    }

    func testNativeSidebarKeepsBothHeroEdgesInTheUncoveredContent() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Native content layout guide requires iOS 26.") }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let item = try await artworkItem(marksSides: true)
        try await withWindow(
            item: item, size: scene.coordinateSpace.bounds.size, sizeClass: nil, insets: .zero,
            pull: PlozziOSHomeHeroPullModel(), nativeTabs: true
        ) { window, host in
            let tabs = try XCTUnwrap(findController(UITabBarController.self, in: host))
            let delegate = tabs.sidebar.delegate
            for size in [CGSize(width: 1194, height: 834), CGSize(width: 834, height: 1194)] {
                window.frame = CGRect(origin: .zero, size: size)
                try await waitForHostedLayout(window)
                var fullWidthSamples: [[UInt8]]?
                for hidden in [true, false, true, false] {
                    tabs.sidebar.isHidden = hidden
                    try await waitForHostedLayout(window)
                    let safe = tabs.view.convert(tabs.contentLayoutGuide.layoutFrame, to: window)
                    XCTAssertEqual(tabs.sidebar.isHidden, hidden)
                    XCTAssertTrue(tabs.sidebar.delegate === delegate)
                    let probe = try XCTUnwrap(findController(PlozziOSHomeSidebarOverlapProbe.ProbeController.self, in: host))
                    XCTAssertTrue(probe.tabBarController === tabs)
                    XCTAssertEqual(probe.geometryModel?.isVisible, !hidden)
                    if !hidden {
                        XCTAssertEqual(try XCTUnwrap(probe.geometryModel?.coveredWidth), safe.minX, accuracy: 1)
                        XCTAssertGreaterThan(safe.minX, 100)
                    }
                    let image = snapshot(window, name: "native-sidebar-\(Int(size.width))-hidden-\(hidden)")
                    let left = try pixel(image, at: CGPoint(x: safe.minX + safe.width * 0.05, y: 150))
                    let right = try pixel(image, at: CGPoint(x: safe.maxX - safe.width * 0.05, y: 150))
                    if !hidden {
                        XCTAssertGreaterThan(Int(left[0]) - Int(left[2]), 100, "The red left edge must remain beside the sidebar.")
                        XCTAssertGreaterThan(Int(right[1]) - Int(right[2]), 100, "The green right edge must remain visible.")
                        let reflection = try pixel(image, at: CGPoint(x: safe.minX - 50, y: 250))
                        XCTAssertGreaterThan(Int(reflection[0]) - Int(reflection[2]), 8,
                                             "The blurred reflection must retain the red edge's hue, not paint a black strip.")
                    } else {
                        let samples = try [CGFloat(0.1), 0.5, 0.9].map {
                            try pixel(image, at: CGPoint(x: window.bounds.width * $0, y: 150))
                        }
                        if let fullWidthSamples {
                            XCTAssertEqual(samples, fullWidthSamples, "Closing the sidebar must restore full-width artwork.")
                        } else {
                            fullWidthSamples = samples
                        }
                    }
                }
            }
            let probe = try XCTUnwrap(findController(PlozziOSHomeSidebarOverlapProbe.ProbeController.self, in: host))
            let model = try XCTUnwrap(probe.geometryModel)
            PlozziOSHomeSidebarOverlapProbe.dismantleUIViewController(probe, coordinator: ())
            XCTAssertFalse(descendants(tabs.view).contains { $0 is PlozziOSHomeSidebarOverlapProbe.ProbeController.GeometryView })
            XCTAssertFalse(model.isVisible)
        }
    }

    func testSidebarArtworkKeepsTheSameFramingAtSwipeLanding() async throws {
        let item = try await artworkItem(marksSides: true)
        try await withWindow(
            item: item, size: CGSize(width: 1024, height: 768), sizeClass: .regular,
            insets: .zero, pull: PlozziOSHomeHeroPullModel()
        ) { window, host in
            let sidebar = PlozziOSSidebarGeometryModel()
            sidebar.recordCoveredWidth(280)
            sidebar.setVisible(true)
            let trailer = HeroTrailerController()
            var idleSamples: [[UInt8]]?
            for sliding in [false, true, false] {
                host.rootView = AnyView(
                    PlozziOSHomeStaticBackdrop(
                        item: item, style: .landscape, height: 680,
                        showsTrailer: false, usesSlidingArtwork: sliding
                    )
                    .frame(maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea()
                    .environment(sidebar)
                    .environment(trailer)
                    .environment(\.themePalette, .dark)
                    .environment(\.colorScheme, .dark)
                )
                try await waitForHostedLayout(window)
                let image = snapshot(window, name: "sidebar-swipe-landing-\(sliding)")
                let samples = try [CGPoint(x: 310, y: 150), CGPoint(x: 650, y: 150), CGPoint(x: 980, y: 150)].map {
                    try pixel(image, at: $0)
                }
                XCTAssertGreaterThan(Int(samples[0][0]) - Int(samples[0][2]), 100)
                XCTAssertGreaterThan(Int(samples[2][1]) - Int(samples[2][2]), 100)
                if let idleSamples {
                    XCTAssertEqual(samples, idleSamples, "Landing must not crop or recenter the complete image.")
                } else {
                    idleSamples = samples
                }
            }
        }
    }

    private func artworkItem(marksTop: Bool = false, marksSides: Bool = false) async throws -> MediaItem {
        let url = try XCTUnwrap(URL(string: "https://hero-width.invalid/\(UUID().uuidString).png"))
        let size = marksTop || marksSides ? CGSize(width: 1_600, height: 900) : CGSize(width: 900, height: 1_200)
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
            if marksSides {
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 240, height: size.height))
                UIColor.green.setFill()
                context.fill(CGRect(x: size.width - 240, y: 0, width: 240, height: size.height))
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
private struct PushedDetailTransparencyFixture: View {
    let app: PlozziOSAppModel
    let provider: SeriesHeaderMobileProvider
    @State private var showsDetail = false

    var body: some View {
        NavigationStack {
            Color.clear
                .navigationDestination(isPresented: $showsDetail) {
                    PlozziOSItemDetailView(appModel: app, provider: provider, item: provider.show)
                        .toolbarBackground(.hidden, for: .navigationBar)
                }
                .task {
                    await Task.yield()
                    withAnimation { showsDetail = true }
                }
        }
    }
}

@available(iOS 26.0, *)
private struct MacNavigationBackgroundFixture: View {
    var hidesTopBackdrop = false

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
                                Text(verbatim: "PROFILE").font(.title2).foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }
            Tab("Search", systemImage: "magnifyingglass", role: .search) { Text("Search") }
        }
        .tabViewStyle(.sidebarAdaptable)
        .scrollEdgeEffectStyle(.hard, for: .top)
        .modifier(PlozziOSNavigationBackground(hidesTopBackdrop: hidesTopBackdrop))
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
            .background {
                if nativeTabs {
                    PlozziOSHomeSidebarOverlapProbe(enabled: true, geometryModel: sidebar)
                        .frame(width: 0, height: 0)
                }
            }
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
